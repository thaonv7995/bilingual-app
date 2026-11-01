import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useToast } from '@/components/Toast';
import {
  AuthRefreshError,
  accessTokenExpiresSoon,
  ensureFreshAccessToken,
  getAccessToken,
} from '@/lib/api-client';
import { readJSON, readString, writeJSON, writeString } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import { ChatSidebar } from '@/features/chat/ChatSidebar';
import { SettingsModal } from '@/features/settings/SettingsModal';
import { useSettingsStore } from '@/features/settings/settingsStore';
import { useAuthStore } from '@/features/auth/authStore';
import {
  useBooks,
  useUpdateBookAppearanceDefaults,
  useUpdateBookState,
} from '@/features/library/useBooks';
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
import { ReaderAppearancePopover } from './ReaderAppearancePopover';
import {
  getLocalBookAppearance,
  parseThemeDescriptor,
  preloadSingleReaderFont,
  resolveEffectiveBookAppearance,
  saveLocalBookAppearance,
  serializeThemeDescriptor,
  type LocalBookAppearance,
} from './readerAppearance';
import { AudiobookBar } from '@/features/audiobook/AudiobookBar';
import { useAudiobook, type AudiobookLanguageMode } from '@/features/audiobook/useAudiobook';
import {
  applyBookAppearance,
  injectReaderStyles,
  resolveBookBackground,
  setVocaPanelCss,
} from './iframe/readerStyles';
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

const AUTH_ERROR_MARKERS = [
  'Access Denied: Please log in first',
  'Not authenticated',
  'Invalid or expired JWT',
];

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
  const updateBookState = useUpdateBookState();
  const updateBookAppearanceDefaults = useUpdateBookAppearanceDefaults();

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
  const [audiobookOpen, setAudiobookOpen] = useState(false);
  const [appearanceOpen, setAppearanceOpen] = useState(false);
  const [localAppearance, setLocalAppearance] = useState<LocalBookAppearance>(() =>
    getLocalBookAppearance(book.slug),
  );
  const enIframeRef = useRef<HTMLIFrameElement | null>(null);
  const viIframeRef = useRef<HTMLIFrameElement | null>(null);

  // Sync server-provided per-book appearance override when book metadata refreshes
  useEffect(() => {
    if (book.readerFont !== undefined || book.readerTheme !== undefined) {
      setLocalAppearance((prev) => {
        const next: LocalBookAppearance = {
          readerFont: book.readerFont ?? prev.readerFont ?? '',
          readerTheme: book.readerTheme ?? prev.readerTheme ?? '',
        };
        saveLocalBookAppearance(book.slug, next);
        return next;
      });
    }
  }, [book.slug, book.readerFont, book.readerTheme]);

  const resolvedAppearance = useMemo(
    () => resolveEffectiveBookAppearance(book, localAppearance),
    [book, localAppearance],
  );
  const {
    effectiveFontId,
    effectiveThemeId,
    bookDefaultFontId,
    bookDefaultThemeId,
    hasUserFontOverride,
    hasUserThemeOverride,
  } = resolvedAppearance;
  const hasUserAppearanceOverride = hasUserFontOverride || hasUserThemeOverride;
  const hasCustomAppearance = effectiveFontId !== 'default' || effectiveThemeId !== 'default';

  const appearanceRef = useRef({ fontId: effectiveFontId, themeId: effectiveThemeId });
  const appearanceOpenRef = useRef(appearanceOpen);
  appearanceOpenRef.current = appearanceOpen;
  const paneA4Ref = useRef<{
    en?: { appliedFontScale: number; clampedByA4: boolean; atMaxA4Scale: boolean };
    vi?: { appliedFontScale: number; clampedByA4: boolean; atMaxA4Scale: boolean };
  }>({});
  const [a4Status, setA4Status] = useState<{
    appliedFontScale: number;
    clampedByA4: boolean;
    atMaxA4Scale: boolean;
  }>({
    appliedFontScale: 100,
    clampedByA4: false,
    atMaxA4Scale: false,
  });

  const syncAppearanceAndMeasureA4 = useCallback(
    (fontId: string, themeId: string, measureMaxScale = appearanceOpenRef.current) => {
      const results = [];
      if (enIframeRef.current?.contentDocument) {
        const enRes = applyBookAppearance(
          enIframeRef.current.contentDocument,
          enIframeRef.current,
          { fontId, themeId, measureMaxScale },
        );
        paneA4Ref.current.en = enRes;
        results.push(enRes);
      }
      if (viIframeRef.current?.contentDocument) {
        const viRes = applyBookAppearance(
          viIframeRef.current.contentDocument,
          viIframeRef.current,
          { fontId, themeId, measureMaxScale },
        );
        paneA4Ref.current.vi = viRes;
        results.push(viRes);
      }
      if (results.length > 0) {
        const appliedFontScale = Math.min(...results.map((r) => r.appliedFontScale));
        const clampedByA4 = results.some((r) => r.clampedByA4);
        const atMaxA4Scale = results.some((r) => r.atMaxA4Scale);
        setA4Status({ appliedFontScale, clampedByA4, atMaxA4Scale });
        return { appliedFontScale, clampedByA4, atMaxA4Scale };
      }
      const reqScale = parseThemeDescriptor(themeId).fontScale || 100;
      const fallback = {
        appliedFontScale: reqScale,
        clampedByA4: false,
        atMaxA4Scale: reqScale >= 140,
      };
      setA4Status(fallback);
      return fallback;
    },
    [],
  );

  useEffect(() => {
    preloadSingleReaderFont(effectiveFontId);
    appearanceRef.current = { fontId: effectiveFontId, themeId: effectiveThemeId };
    syncAppearanceAndMeasureA4(effectiveFontId, effectiveThemeId, appearanceOpen);
  }, [effectiveFontId, effectiveThemeId, appearanceOpen, syncAppearanceAndMeasureA4]);

  const handleSelectFont = useCallback(
    (fontId: string) => {
      const nextFont = fontId === bookDefaultFontId ? '' : fontId;
      const next: LocalBookAppearance = {
        ...localAppearance,
        readerFont: nextFont,
      };
      setLocalAppearance(next);
      saveLocalBookAppearance(book.slug, next);
      updateBookState.mutate({
        slug: book.slug,
        patch: { readerFont: nextFont },
      });
    },
    [book.slug, bookDefaultFontId, localAppearance, updateBookState],
  );

  const handleSelectTheme = useCallback(
    (themeId: string) => {
      const prevScale = parseThemeDescriptor(effectiveThemeId).fontScale || 100;
      const requestedDesc = parseThemeDescriptor(themeId);
      const measured = syncAppearanceAndMeasureA4(effectiveFontId, themeId, true);

      let finalThemeId = themeId;
      if (measured.clampedByA4 && requestedDesc.fontScale > measured.appliedFontScale) {
        finalThemeId = serializeThemeDescriptor({
          ...requestedDesc,
          fontScale: measured.appliedFontScale,
        });
        if (requestedDesc.fontScale > prevScale) {
          toast.info(
            `Đã chạm giới hạn trang A4 (${measured.appliedFontScale}%) — không thể tăng chữ lớn hơn.`,
          );
        }
      }

      const nextTheme = finalThemeId === bookDefaultThemeId ? '' : finalThemeId;
      const next: LocalBookAppearance = {
        ...localAppearance,
        readerTheme: nextTheme,
      };
      setLocalAppearance(next);
      saveLocalBookAppearance(book.slug, next);
      updateBookState.mutate({
        slug: book.slug,
        patch: { readerTheme: nextTheme },
      });
    },
    [
      book.slug,
      bookDefaultThemeId,
      effectiveFontId,
      effectiveThemeId,
      localAppearance,
      syncAppearanceAndMeasureA4,
      toast,
      updateBookState,
    ],
  );

  const handleResetAppearanceToBookDefault = useCallback(() => {
    if (hasUserAppearanceOverride) {
      const cleared: LocalBookAppearance = { readerFont: '', readerTheme: '' };
      setLocalAppearance(cleared);
      saveLocalBookAppearance(book.slug, cleared);
      updateBookState.mutate({
        slug: book.slug,
        patch: { readerFont: '', readerTheme: '' },
      });
      toast.info('Đã trở về phông chữ & màu giấy mặc định của sách.');
    } else if (bookDefaultFontId !== 'default' || bookDefaultThemeId !== 'default') {
      updateBookAppearanceDefaults.mutate(
        {
          slug: book.slug,
          patch: { defaultFont: 'default', defaultTheme: 'default' },
        },
        {
          onSuccess: () => {
            toast.info('Đã đặt mặc định của sách về thiết kế CSS gốc.');
          },
        },
      );
    }
  }, [
    book.slug,
    bookDefaultFontId,
    bookDefaultThemeId,
    hasUserAppearanceOverride,
    toast,
    updateBookAppearanceDefaults,
    updateBookState,
  ]);

  const handleSaveAsBookDefault = useCallback(() => {
    updateBookAppearanceDefaults.mutate(
      {
        slug: book.slug,
        patch: {
          defaultFont: effectiveFontId,
          defaultTheme: effectiveThemeId,
        },
      },
      {
        onSuccess: () => {
          const cleared: LocalBookAppearance = { readerFont: '', readerTheme: '' };
          setLocalAppearance(cleared);
          saveLocalBookAppearance(book.slug, cleared);
          updateBookState.mutate({
            slug: book.slug,
            patch: { readerFont: '', readerTheme: '' },
          });
          toast.success(`Đã lưu cấu hình mặc định cho sách "${book.title}"!`);
        },
        onError: () => {
          toast.error('Không thể lưu cấu hình mặc định của sách.');
        },
      },
    );
  }, [
    book.slug,
    book.title,
    effectiveFontId,
    effectiveThemeId,
    toast,
    updateBookAppearanceDefaults,
    updateBookState,
  ]);

  const audiobook = useAudiobook({
    bookSlug: book.slug,
    currentPage: page,
    totalPage: book.pageCount,
    viewMode,
    enIframeRef,
    viIframeRef,
    enabled: audiobookOpen,
    onNextPage: () => void requestPageChange((p) => p + 1),
  });

  // Ref holds the latest keyboard handler so both parent window and iframe
  // documents always invoke fresh state/callbacks without re-binding listeners.
  const onKeyRef = useRef<(e: KeyboardEvent) => void>(() => {});

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
      onKeyDown: (e) => onKeyRef.current(e),
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

  // -- page navigation (sequence-guarded, optimistic) -------------------------
  const requestPageChange = useCallback(
    async (targetOrUpdater: number | ((base: number) => number)) => {
      if (!book.pageCount) return;
      const base = requestedPageRef.current;
      const requested =
        typeof targetOrUpdater === 'function' ? targetOrUpdater(base) : targetOrUpdater;
      const target = Math.max(1, Math.min(book.pageCount, Number(requested) || 1));
      if (target === base) return;

      requestedPageRef.current = target;
      userNavigatedRef.current = true;
      const seq = ++navSeqRef.current;

      // Fast path: when the token is still fresh, flip page synchronously (0ms delay).
      const token = getAccessToken();
      if (token && !accessTokenExpiresSoon(token)) {
        setPage(target);
        return;
      }

      // Refresh the cookie the iframe uses only when missing or expiring within 60s.
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

  const handleAudiobookModeChange = useCallback(
    (newMode: AudiobookLanguageMode) => {
      audiobook.changeMode(newMode);
      if (newMode === 'vi' && viewMode === 'en') {
        setViewMode('vi');
      } else if (newMode === 'en' && viewMode === 'vi') {
        setViewMode('en');
      }
    },
    [audiobook, viewMode, setViewMode],
  );

  const handleSetViewMode = useCallback(
    (newViewMode: ViewMode) => {
      setViewMode(newViewMode);
      if (audiobookOpen) {
        if (newViewMode === 'en' && audiobook.mode === 'vi') {
          audiobook.changeMode('en');
        } else if (newViewMode === 'vi' && audiobook.mode === 'en') {
          audiobook.changeMode('vi');
        }
      }
    },
    [setViewMode, audiobookOpen, audiobook],
  );

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
        const pathname = iframeEl.contentWindow?.location?.pathname || '';
        const pageMatch = pathname.match(/page_(\d+)\.html$/i);
        const loadedPage = pageMatch ? parseInt(pageMatch[1]!, 10) : requestedPageRef.current;
        const retryKey = `${book.slug}:${loadedPage}:${lang}`;
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

        // Style only the iframe that just loaded instead of re-measuring both panes twice.
        const measured = applyBookAppearance(doc, iframeEl, {
          fontId: appearanceRef.current.fontId,
          themeId: appearanceRef.current.themeId,
          measureMaxScale: appearanceOpenRef.current,
        });
        paneA4Ref.current[lang] = measured;
        const activeResults = [
          enIframeRef.current?.contentDocument ? paneA4Ref.current.en : undefined,
          viIframeRef.current?.contentDocument ? paneA4Ref.current.vi : undefined,
        ].filter((r): r is NonNullable<typeof r> => Boolean(r));
        if (activeResults.length > 0) {
          setA4Status({
            appliedFontScale: Math.min(...activeResults.map((r) => r.appliedFontScale)),
            clampedByA4: activeResults.some((r) => r.clampedByA4),
            atMaxA4Scale: activeResults.some((r) => r.atMaxA4Scale),
          });
        }

        segmentDocSentences(doc);
        applyStoredHighlights(doc, book.slug, loadedPage, lang);
        const win = iframeEl.contentWindow;
        if (win) registerIframeHighlightListeners(win, doc, lang);
      } catch (err) {
        console.warn('[Reader] could not style iframe content:', err);
      }
    },
    [book.slug, scaleIframes, toast],
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

  // Keyboard navigation + shortcuts (J/K, ArrowLeft/Right, PageUp/Down, F, 1/2/3, A)
  // Shared between parent `window` and both book `<iframe>` documents via `onKeyRef`.
  onKeyRef.current = (e: KeyboardEvent) => {
    const target =
      (e.target as HTMLElement | null) ?? (document.activeElement as HTMLElement | null);
    if (
      target &&
      (target.tagName === 'INPUT' ||
        target.tagName === 'TEXTAREA' ||
        target.tagName === 'SELECT' ||
        target.isContentEditable)
    ) {
      return;
    }
    if (handleZoomShortcut(e)) return;

    const key = e.key.toLowerCase();
    if (e.key === 'ArrowLeft' || e.key === 'PageUp' || key === 'k') {
      e.preventDefault();
      void requestPageChange((p) => p - 1);
    } else if (e.key === 'ArrowRight' || e.key === 'PageDown' || key === 'j') {
      e.preventDefault();
      void requestPageChange((p) => p + 1);
    } else if (key === 'f' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      selectZoomMode(zoomMode === 'fit-page' ? 'fit-width' : 'fit-page');
    } else if (e.key === '1' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      setViewMode('en');
    } else if (e.key === '2' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      setViewMode('vi');
    } else if (e.key === '3' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      setViewMode('split');
    } else if (key === 'a' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      setAppearanceOpen((v) => !v);
    }
  };

  useEffect(() => {
    const onWindowKey = (e: KeyboardEvent) => onKeyRef.current(e);
    window.addEventListener('keydown', onWindowKey);
    return () => window.removeEventListener('keydown', onWindowKey);
  }, []);

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

  // Background prefetch of adjacent pages (page + 1, page + 2, page - 1) so
  // turning pages via keyboard or toolbar hits the browser cache immediately.
  const prefetchedUrlsRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    if (!book.pageCount) return;
    const langs: ('en' | 'vi')[] = [];
    if (showEn) langs.push('en');
    if (showVi) langs.push('vi');
    if (langs.length === 0) return;

    const timer = window.setTimeout(() => {
      const candidates = [page + 1, page + 2, page - 1].filter(
        (p) => p >= 1 && p <= book.pageCount,
      );
      for (const candidatePage of candidates) {
        for (const lang of langs) {
          const url = `/books/${encodeURIComponent(book.slug)}/output/${lang}/page_${padPage(candidatePage)}.html`;
          if (prefetchedUrlsRef.current.has(url)) continue;
          prefetchedUrlsRef.current.add(url);
          void fetch(url, { credentials: 'include', priority: 'low' } as RequestInit).catch(
            () => {
              prefetchedUrlsRef.current.delete(url);
            },
          );
        }
      }
    }, 120);

    return () => window.clearTimeout(timer);
  }, [book.slug, book.pageCount, page, showEn, showVi]);

  return (
    <div className="reader-view">
      <ReaderTopbar
        book={book}
        page={page}
        viewMode={viewMode}
        zoomMode={zoomMode}
        zoomLevel={displayedZoom}
        chatOpen={chatOpen}
        isBookFinished={book.isFinished}
        isUpdatingFinished={updateBookState.isPending}
        username={user?.username ?? ''}
        isAdmin={user?.is_admin ?? false}
        onHome={() => navigate('/')}
        onGoToPage={(p) => void requestPageChange(p)}
        onStep={(delta) => void requestPageChange((p) => p + delta)}
        onSetViewMode={handleSetViewMode}
        onSelectZoomMode={selectZoomMode}
        onAdjustZoom={adjustReaderZoom}
        onToggleChat={toggleChat}
        onToggleFinished={() =>
          updateBookState.mutate({
            slug: book.slug,
            patch: { isFinished: !book.isFinished },
          })
        }
        onOpenSettings={() => setSettingsOpen(true)}
        audiobookOpen={audiobookOpen}
        onToggleAudiobook={() => setAudiobookOpen((v) => !v)}
        appearanceOpen={appearanceOpen}
        hasCustomAppearance={hasCustomAppearance}
        onToggleAppearance={() => setAppearanceOpen((v) => !v)}
        onLogout={logout}
      />

      {appearanceOpen && (
        <ReaderAppearancePopover
          bookTitle={book.title}
          effectiveFontId={effectiveFontId}
          effectiveThemeId={effectiveThemeId}
          bookDefaultFontId={bookDefaultFontId}
          bookDefaultThemeId={bookDefaultThemeId}
          hasUserOverride={hasUserAppearanceOverride}
          isSavingDefault={updateBookAppearanceDefaults.isPending}
          appliedFontScale={a4Status.appliedFontScale}
          clampedByA4={a4Status.clampedByA4}
          atMaxA4Scale={a4Status.atMaxA4Scale}
          onSelectFont={handleSelectFont}
          onSelectTheme={handleSelectTheme}
          onResetToBookDefault={handleResetAppearanceToBookDefault}
          onSaveAsBookDefault={handleSaveAsBookDefault}
          onClose={() => setAppearanceOpen(false)}
        />
      )}

      <div className={`reader-workspace ${chatOpen ? 'chat-open' : ''}`}>
        <div className={`reader-panes layout-${layoutMode}`}>
          {showEn && (
            <div className="reader-pane" id="en-pane">
              <span className="pane-label">EN</span>
              <div className="iframe-wrapper">
                <div className="iframe-stage">
                  <iframe
                    ref={enIframeRef}
                    className="reader-iframe en-pane-iframe"
                    src={enPageUrl}
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
                    ref={viIframeRef}
                    className="reader-iframe vi-pane-iframe"
                    src={viPageUrl}
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
          onClose={toggleChat}
          onWidthChange={(w) => {
            setChatWidth(w);
            writeString(STORAGE_KEYS.chatWidth, String(w));
          }}
          onResizing={scaleIframes}
        />
      </div>

      {settingsOpen && <SettingsModal onClose={() => setSettingsOpen(false)} />}

      {audiobookOpen && (
        <AudiobookBar
          isPlaying={audiobook.isPlaying}
          currentSentenceIndex={audiobook.currentSentenceIndex}
          totalSentences={audiobook.totalSentences}
          currentLang={audiobook.currentSentence?.lang || null}
          mode={audiobook.mode}
          speed={audiobook.speed}
          provider={audiobook.provider}
          error={audiobook.error}
          onPlay={audiobook.play}
          onPause={audiobook.pause}
          onNext={audiobook.nextSentence}
          onPrev={audiobook.prevSentence}
          onModeChange={handleAudiobookModeChange}
          onSpeedChange={audiobook.setSpeed}
          onClose={() => {
            audiobook.pause();
            setAudiobookOpen(false);
          }}
        />
      )}
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
