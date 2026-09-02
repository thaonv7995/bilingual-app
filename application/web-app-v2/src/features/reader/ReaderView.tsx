import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useToast } from '@/components/Toast';
import { AuthRefreshError, ensureFreshAccessToken } from '@/lib/api-client';
import { readJSON, readString, writeJSON, writeString } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import { ChatSidebar } from '@/features/chat/ChatSidebar';
import { useVoice } from '@/features/voice/useVoice';
import { SettingsModal } from '@/features/settings/SettingsModal';
import { useSettingsStore } from '@/features/settings/settingsStore';
import { useAuthStore } from '@/features/auth/authStore';
import { useBooks } from '@/features/library/useBooks';
import type { Book, ViewMode } from '@/types/api';
import {
  cleanWord,
  getVocaLookupPanelCss,
  lookupWord,
  showVocaError,
  showVocaLookupResults,
  showVocaNotFoundPanel,
  syncVocaCards,
} from '@/lib/voca';
import { ReaderTopbar } from './ReaderTopbar';
import { injectReaderStyles, resolveBookBackground, setVocaPanelCss } from './iframe/readerStyles';
import { segmentDocSentences } from './iframe/segmentation';

// Make the voca lookup-panel CSS part of the styles injected into each iframe.
setVocaPanelCss(getVocaLookupPanelCss());
import {
  applyStoredHighlights,
  clearAllHighlights,
  registerIframeHighlightListeners,
  removeAllReaderHighlightUI,
  setHighlightContext,
} from './iframe/highlightDom';
import { useHighlights } from './useHighlights';
import { getLocalProgress, saveLocalProgress } from './localProgress';
import { resolveProgressOnOpen } from './progressSync';
import { useSaveProgress, useServerProgress } from './useReaderProgress';
import {
  READER_PAGE_HEIGHT,
  READER_PAGE_WIDTH,
  READER_VIEWPORT_PADDING,
  READER_ZOOM_STEP,
  clampReaderZoom,
  padPage,
  type ZoomMode,
} from './readerConstants';
import './reader.css';

const AUTH_ERROR_MARKERS = ['Access Denied: Please log in first', 'Not authenticated', 'Invalid or expired JWT'];

export function ReaderView() {
  const { slug = '', page: pageParam } = useParams();
  const navigate = useNavigate();
  const { data: books, isLoading } = useBooks();
  const book = useMemo(() => books?.find((b) => b.slug === slug), [books, slug]);

  if (isLoading && !books) return <ReaderSplash />;
  if (!book) {
    navigate('/', { replace: true });
    return null;
  }
  return <Reader key={slug} book={book} initialPageParam={pageParam} />;
}

function Reader({ book, initialPageParam }: { book: Book; initialPageParam?: string }) {
  const navigate = useNavigate();
  const toast = useToast();
  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);

  const local = useMemo(() => getLocalProgress(book.slug), [book.slug]);
  // Captured at mount: the URL-sync effect rewrites the URL to /page/:page
  // right away, which would otherwise flip this to true before the server
  // reconcile effect ever ran. Only a page the user ARRIVED with counts.
  const hadExplicitPageRef = useRef(initialPageParam != null);
  const hadExplicitPage = hadExplicitPageRef.current;

  const [page, setPage] = useState(() => {
    const fromUrl = initialPageParam ? parseInt(initialPageParam, 10) : NaN;
    const initial = !isNaN(fromUrl) ? fromUrl : (local?.page ?? 1);
    return Math.max(1, Math.min(book.pageCount || 1, initial));
  });
  const [viewMode, setViewModeState] = useState<ViewMode>(() => local?.viewMode ?? 'en');
  const layoutMode = useSettingsStore((s) => s.settings.layoutMode);
  const [zoomMode, setZoomMode] = useState<ZoomMode>(
    () => (readString(STORAGE_KEYS.zoomMode) as ZoomMode) || 'fit-page',
  );
  const [manualZoom, setManualZoom] = useState<number>(
    () => parseFloat(readString(STORAGE_KEYS.zoomScale) || '') || 1,
  );
  // The zoom label shows the ACTUAL displayed scale (which in fit modes differs
  // from manualZoom), matching v1 where scaleIframes rewrote the label directly.
  const [displayedZoom, setDisplayedZoom] = useState<number>(manualZoom);

  // Refs mirror zoom state for the imperative scaleIframes (runs in rAF/events).
  const zoomModeRef = useRef(zoomMode);
  const manualZoomRef = useRef(manualZoom);
  const currentZoomRef = useRef(manualZoom);
  const shownZoomRef = useRef(manualZoom);
  useEffect(() => void (zoomModeRef.current = zoomMode), [zoomMode]);
  useEffect(() => void (manualZoomRef.current = manualZoom), [manualZoom]);

  // Navigation guards (ported from v1 app.js:486-488, 883-914).
  const requestedPageRef = useRef(page);
  const navSeqRef = useRef(0);
  const iframeAuthRetriesRef = useRef<Set<string>>(new Set());
  const userNavigatedRef = useRef(false);

  const saveProgress = useSaveProgress(book.slug);
  const { data: serverProgress, isFetching: progressFetching } = useServerProgress(book.slug);
  const appliedServerRef = useRef(false);

  const { highlights, createHighlight, updateHighlight, deleteHighlight } = useHighlights(
    book.slug,
    page,
  );

  const [chatOpen, setChatOpen] = useState<boolean>(() => readJSON(STORAGE_KEYS.chatOpen, false));
  const [chatWidth, setChatWidth] = useState<number>(
    () => parseInt(readString(STORAGE_KEYS.chatWidth) || '', 10) || 400,
  );
  const toggleChat = useCallback(() => {
    setChatOpen((v) => {
      writeJSON(STORAGE_KEYS.chatOpen, !v);
      return !v;
    });
  }, []);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Refresh the local Voca mirror once per open so lookups answer from cache.
  // Incremental + throttled: costs one tiny request when nothing changed.
  useEffect(() => {
    void syncVocaCards().catch(() => {
      /* offline / Voca not configured — lookups fall back to the network */
    });
  }, []);

  // Keep the imperative highlight layer's context fresh every render (v2's
  // typed replacement for v1's reassigned `highlightAppContext` global).
  useEffect(() => {
    setHighlightContext({
      slug: book.slug,
      page,
      createHighlight,
      updateHighlight,
      deleteHighlight,
      onLookup: async (text, doc, anchorRect) => {
        const word = cleanWord(text);
        if (!word) return;
        try {
          const result = await lookupWord(word);
          if (result.found) showVocaLookupResults(doc, anchorRect, word, result);
          else showVocaNotFoundPanel(doc, anchorRect, word);
        } catch (err) {
          showVocaError(err instanceof Error ? err.message : 'Tra cứu thất bại.');
        }
      },
    });
    return () => setHighlightContext(null);
  }, [book.slug, page, createHighlight, updateHighlight, deleteHighlight]);

  const enPageUrl = `/books/${encodeURIComponent(book.slug)}/output/en/page_${padPage(page)}.html`;
  const viPageUrl = `/books/${encodeURIComponent(book.slug)}/output/vi/page_${padPage(page)}.html`;

  // -- scaling (A4 page -> fit) — ported from app.js:1098-1135 ---------------
  const scaleIframes = useCallback(() => {
    const wrappers = document.querySelectorAll<HTMLElement>('.iframe-wrapper');
    let displayedScale: number | null = null;

    wrappers.forEach((wrapper) => {
      const iframe = wrapper.querySelector<HTMLElement>('.reader-iframe');
      const stage = wrapper.querySelector<HTMLElement>('.iframe-stage');
      if (!iframe || !stage) return;

      const availableWidth = Math.max(wrapper.clientWidth - READER_VIEWPORT_PADDING, 100);
      const availableHeight = Math.max(wrapper.clientHeight - READER_VIEWPORT_PADDING, 100);
      const fitWidthScale = availableWidth / READER_PAGE_WIDTH;
      const fitPageScale = Math.min(fitWidthScale, availableHeight / READER_PAGE_HEIGHT);

      let scale = manualZoomRef.current;
      if (zoomModeRef.current === 'fit-page') scale = fitPageScale;
      if (zoomModeRef.current === 'fit-width') scale = fitWidthScale;
      scale = clampReaderZoom(scale, 0.2);

      iframe.style.transform = `scale(${scale})`;
      iframe.style.width = `${READER_PAGE_WIDTH}px`;
      iframe.style.height = `${READER_PAGE_HEIGHT}px`;
      stage.style.width = `${READER_PAGE_WIDTH * scale}px`;
      stage.style.height = `${READER_PAGE_HEIGHT * scale}px`;
      wrapper.dataset.zoomScale = String(scale);
      if (displayedScale === null) displayedScale = scale;
    });

    if (displayedScale !== null) {
      currentZoomRef.current = displayedScale;
      if (displayedScale !== shownZoomRef.current) {
        shownZoomRef.current = displayedScale;
        setDisplayedZoom(displayedScale);
      }
    }
  }, []);

  const selectZoomMode = useCallback(
    (mode: ZoomMode) => {
      zoomModeRef.current = mode;
      setZoomMode(mode);
      writeString(STORAGE_KEYS.zoomMode, mode);
      requestAnimationFrame(scaleIframes);
    },
    [scaleIframes],
  );

  const adjustReaderZoom = useCallback(
    (direction: number) => {
      const next = clampReaderZoom(
        Math.round((currentZoomRef.current + direction * READER_ZOOM_STEP) * 100) / 100,
      );
      zoomModeRef.current = 'custom';
      manualZoomRef.current = next;
      currentZoomRef.current = next;
      setZoomMode('custom');
      setManualZoom(next);
      writeString(STORAGE_KEYS.zoomMode, 'custom');
      writeString(STORAGE_KEYS.zoomScale, String(next));
      requestAnimationFrame(scaleIframes);
    },
    [scaleIframes],
  );

  const handleZoomShortcut = useCallback(
    (event: KeyboardEvent): boolean => {
      if (event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
        const key = event.key.toLowerCase();
        if (key === 'p') {
          event.preventDefault();
          selectZoomMode('fit-page');
          return true;
        }
        if (key === 'w') {
          event.preventDefault();
          selectZoomMode('fit-width');
          return true;
        }
      }
      if (!(event.ctrlKey || event.metaKey) || event.altKey) return false;
      if (event.key === '+' || event.key === '=') {
        event.preventDefault();
        adjustReaderZoom(1);
        return true;
      }
      if (event.key === '-') {
        event.preventDefault();
        adjustReaderZoom(-1);
        return true;
      }
      if (event.key === '0') {
        event.preventDefault();
        selectZoomMode('fit-page');
        return true;
      }
      return false;
    },
    [selectZoomMode, adjustReaderZoom],
  );

  // -- page navigation (sequence-guarded) — ported from app.js:883-914 -------
  const requestPageChange = useCallback(
    async (targetOrUpdater: number | ((base: number) => number)) => {
      if (!book.pageCount) return;
      const base = requestedPageRef.current;
      const requested = typeof targetOrUpdater === 'function' ? targetOrUpdater(base) : targetOrUpdater;
      const target = Math.max(1, Math.min(book.pageCount, Number(requested) || 1));
      if (target === base) return;

      requestedPageRef.current = target;
      userNavigatedRef.current = true;
      const seq = ++navSeqRef.current;

      // Refresh the cookie the iframe uses, if it's about to expire. Best-effort:
      // offline / cached pages still load, and the iframe onLoad retry recovers.
      try {
        await ensureFreshAccessToken();
      } catch {
        /* proceed; cached page may serve, iframe retry handles auth */
      }
      if (seq === navSeqRef.current) setPage(target);
    },
    [book.pageCount],
  );

  const setViewMode = useCallback(
    (mode: ViewMode) => {
      setViewModeState(mode);
      writeString(STORAGE_KEYS.viewMode, mode);
      saveProgress(page, mode);
    },
    [page, saveProgress],
  );

  // Realtime voice lives here (ReaderView holds all reader state) so its tools
  // and page-context injection see the live page/highlights.
  const voice = useVoice({
    book,
    page,
    viewMode,
    highlights,
    requestPageChange,
    setViewMode,
    createHighlight,
    deleteHighlight,
  });

  // -- iframe load: auth-retry, BKB paper sync, hide internal nav --------------
  const handleIframeLoad = useCallback(
    (e: React.SyntheticEvent<HTMLIFrameElement>) => {
      scaleIframes();
      const iframeEl = e.currentTarget;
      try {
        const doc = iframeEl.contentDocument;
        if (!doc) return;
        const isEnglish = iframeEl.classList.contains('en-pane-iframe');
        const lang = isEnglish ? 'en' : 'vi';
        const retryKey = `${book.slug}:${page}:${lang}`;
        const bodyText = doc.body?.textContent || '';
        const isAuthError = AUTH_ERROR_MARKERS.some((m) => bodyText.includes(m));

        if (isAuthError) {
          if (!iframeAuthRetriesRef.current.has(retryKey)) {
            iframeAuthRetriesRef.current.add(retryKey);
            ensureFreshAccessToken(true)
              .then(() => iframeEl.contentWindow?.location.reload())
              .catch((err) => {
                if (!(err instanceof AuthRefreshError && err.terminal)) {
                  toast.show('Không tải được trang. Kiểm tra kết nối và thử lại.', 'danger');
                }
              });
          }
          return;
        }

        iframeAuthRetriesRef.current.delete(retryKey);
        doc.documentElement.style.overflow = 'hidden';
        if (doc.body) doc.body.style.overflow = 'hidden';
        const nav = doc.querySelector<HTMLElement>('.page-nav');
        if (nav) nav.style.display = 'none';

        iframeEl.style.backgroundColor = resolveBookBackground(doc);
        injectReaderStyles(doc, isEnglish);
        segmentDocSentences(doc);
        applyStoredHighlights(doc, book.slug, page, lang);
        const win = iframeEl.contentWindow;
        if (win) registerIframeHighlightListeners(win, doc, lang);
        // Feed the freshly-loaded page to a live voice session (fix #14: v1
        // sent context on page-state change, before the iframe had content).
        voice.sendPageContext(page);
      } catch (err) {
        console.warn('[Reader] could not style iframe content:', err);
      }
    },
    [book.slug, page, scaleIframes, toast, voice],
  );

  // Re-scale on any layout-affecting change (app.js:1191-1194).
  useEffect(() => {
    const timer = setTimeout(scaleIframes, 50);
    return () => clearTimeout(timer);
  }, [viewMode, page, layoutMode, zoomMode, manualZoom, chatOpen, chatWidth, scaleIframes]);

  // Reset wrapper scroll to top on page change (app.js:1196-1203).
  useEffect(() => {
    const timer = setTimeout(() => {
      document.querySelectorAll('.iframe-wrapper').forEach((w) => w.scrollTo({ top: 0, left: 0 }));
    }, 0);
    return () => clearTimeout(timer);
  }, [page]);

  // Window resize re-scales (app.js:1206-1209).
  useEffect(() => {
    window.addEventListener('resize', scaleIframes);
    return () => window.removeEventListener('resize', scaleIframes);
  }, [scaleIframes]);

  // Keyboard navigation + zoom shortcuts (app.js:1438-1458).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) return;
      if (handleZoomShortcut(e)) return;
      if (e.key === 'ArrowLeft' || e.key === 'PageUp') {
        e.preventDefault();
        void requestPageChange((p) => p - 1);
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown') {
        e.preventDefault();
        void requestPageChange((p) => p + 1);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [handleZoomShortcut, requestPageChange]);

  // Scroll-sync EN/VI wrappers for stacked layouts (app.js:1263-1296).
  useEffect(() => {
    const enWrapper = document.querySelector<HTMLElement>('#en-pane .iframe-wrapper');
    const viWrapper = document.querySelector<HTMLElement>('#vi-pane .iframe-wrapper');
    if (!enWrapper || !viWrapper) return;
    let lockEn = false;
    let lockVi = false;
    const onEn = () => {
      if (lockEn) return;
      lockVi = true;
      viWrapper.scrollTop = enWrapper.scrollTop;
      viWrapper.scrollLeft = enWrapper.scrollLeft;
      setTimeout(() => (lockVi = false), 20);
    };
    const onVi = () => {
      if (lockVi) return;
      lockEn = true;
      enWrapper.scrollTop = viWrapper.scrollTop;
      enWrapper.scrollLeft = viWrapper.scrollLeft;
      setTimeout(() => (lockEn = false), 20);
    };
    enWrapper.addEventListener('scroll', onEn);
    viWrapper.addEventListener('scroll', onVi);
    return () => {
      enWrapper.removeEventListener('scroll', onEn);
      viWrapper.removeEventListener('scroll', onVi);
    };
  }, [viewMode, page]);

  // Clicking the app chrome (outside any iframe) clears transient sentence-sync
  // highlights and toolbars (app.js:1248-1260).
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (!(e.target as Element).closest('.reader-iframe')) {
        clearAllHighlights();
        removeAllReaderHighlightUI();
      }
    };
    window.addEventListener('click', onClick);
    return () => window.removeEventListener('click', onClick);
  }, []);

  // Keep the URL in sync with the current page (deep-linkable, no reload loop).
  useEffect(() => {
    const target = `/read/${encodeURIComponent(book.slug)}/page/${page}`;
    if (window.location.pathname !== target) navigate(target, { replace: true });
  }, [book.slug, page, navigate]);

  // Persist + sync progress whenever the user turns a page. Guarded on
  // userNavigatedRef so neither the mount (which would stamp a fresh lastRead
  // on a passive open and could outrank real progress from another device) nor
  // the server-adopt effect below triggers a save — only reading actions do.
  useEffect(() => {
    if (!userNavigatedRef.current) return;
    saveProgress(page, viewMode);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);

  // Reconcile with the backend once its (fresh — see useServerProgress) answer
  // arrives: newer lastRead wins, server wins ties, same rule as iOS. Runs once,
  // and never against a deep-linked page or after the user already navigated —
  // race-safe (review #4).
  useEffect(() => {
    if (appliedServerRef.current || !serverProgress || progressFetching) return;
    appliedServerRef.current = true;
    if (hadExplicitPage || userNavigatedRef.current) return;

    const resolution = resolveProgressOnOpen(local, serverProgress);
    if (resolution.action === 'adopt') {
      const target = Math.max(1, Math.min(book.pageCount || 1, resolution.progress.page));
      requestedPageRef.current = target;
      setPage(target);
      if (resolution.progress.viewMode) setViewModeState(resolution.progress.viewMode);
      // Cache the adopted copy under the SERVER's timestamp — adopting is not
      // a reading action, so it must not gain freshness over other devices.
      saveLocalProgress(book.slug, {
        page: target,
        viewMode: resolution.progress.viewMode ?? viewMode,
        lastRead: resolution.lastReadMs,
      });
    } else if (resolution.action === 'pushLocal') {
      // Local is strictly newer (a save the server never got): re-send it with
      // its original timestamp.
      saveProgress(resolution.progress.page, resolution.progress.viewMode, resolution.lastReadMs);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverProgress, progressFetching, hadExplicitPage]);

  const showEn = viewMode === 'en' || viewMode === 'split';
  const showVi = viewMode === 'vi' || viewMode === 'split';

  return (
    <div className="reader-view">
      <ReaderTopbar
        book={book}
        page={page}
        viewMode={viewMode}
        zoomMode={zoomMode}
        zoomLevel={displayedZoom}
        chatOpen={chatOpen}
        username={user?.username ?? ''}
        isAdmin={user?.is_admin ?? false}
        onHome={() => navigate('/')}
        onGoToPage={(p) => void requestPageChange(p)}
        onStep={(delta) => void requestPageChange((p) => p + delta)}
        onSetViewMode={setViewMode}
        onSelectZoomMode={selectZoomMode}
        onAdjustZoom={adjustReaderZoom}
        onToggleChat={toggleChat}
        onOpenSettings={() => setSettingsOpen(true)}
        onLogout={logout}
      />

      <div className={`reader-workspace ${chatOpen ? 'chat-open' : ''}`}>
        <div className={`reader-panes layout-${layoutMode}`}>
          {showEn && (
            <div className="reader-pane" id="en-pane">
              <span className="pane-label">EN</span>
              <div className="iframe-wrapper">
                <div className="iframe-stage">
                  <iframe
                    className="reader-iframe en-pane-iframe"
                    src={enPageUrl}
                    key={`en-${page}`}
                    onLoad={handleIframeLoad}
                    scrolling="no"
                    sandbox="allow-same-origin"
                    title="English page"
                  />
                </div>
              </div>
            </div>
          )}
          {showVi && (
            <div className="reader-pane" id="vi-pane">
              <span className="pane-label">VI</span>
              <div className="iframe-wrapper">
                <div className="iframe-stage">
                  <iframe
                    className="reader-iframe vi-pane-iframe"
                    src={viPageUrl}
                    key={`vi-${page}`}
                    onLoad={handleIframeLoad}
                    scrolling="no"
                    sandbox="allow-same-origin"
                    title="Vietnamese page"
                  />
                </div>
              </div>
            </div>
          )}
        </div>

        <ChatSidebar
          book={book}
          page={page}
          highlights={highlights}
          open={chatOpen}
          chatWidth={chatWidth}
          voice={voice}
          onClose={toggleChat}
          onWidthChange={(w) => {
            setChatWidth(w);
            writeString(STORAGE_KEYS.chatWidth, String(w));
          }}
          onResizing={scaleIframes}
        />
      </div>

      {settingsOpen && <SettingsModal onClose={() => setSettingsOpen(false)} />}
    </div>
  );
}

function ReaderSplash() {
  return (
    <div style={{ display: 'grid', placeItems: 'center', height: '100%' }}>
      <p style={{ color: 'var(--text-muted)' }}>Đang mở sách…</p>
    </div>
  );
}
