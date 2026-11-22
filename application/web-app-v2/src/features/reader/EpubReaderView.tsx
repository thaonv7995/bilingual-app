import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { FoliateLocation, FoliateTocItem, FoliateViewElement } from 'foliate-js/view.js';
import { ProfileMenu } from '@/components/ProfileMenu';
import { useToast } from '@/components/Toast';
import { apiFetch } from '@/lib/api-client';
import { readJSON, readString, writeJSON, writeString } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import { removeVocaLookupPanel, syncVocaCards } from '@/lib/voca';
import { ChatSidebar } from '@/features/chat/ChatSidebar';
import { SettingsModal } from '@/features/settings/SettingsModal';
import { useAuthStore } from '@/features/auth/authStore';
import { useUpdateBookAppearanceDefaults, useUpdateBookState } from '@/features/library/useBooks';
import type { Book, Highlight } from '@/types/api';
import { HighlightsSidebar } from './HighlightsSidebar';
import { ReaderAppearancePopover } from './ReaderAppearancePopover';
import {
  DocumentSelectionPopover,
  ensureHostVocaStyles,
  type SelectionPopoverState,
} from './DocumentSelectionPopover';
import { parseHighlightAnchor, serializeHighlightAnchor } from './documentAnchors';
import { registerReaderPageContextProvider } from './iframe/pageContext';
import { getLocalProgress, saveLocalProgress } from './localProgress';
import { resolveProgressOnOpen } from './progressSync';
import {
  getLocalBookAppearance,
  getReaderFont,
  getReaderTheme,
  isHexColorDark,
  PAGE_MARGIN_OPTIONS,
  parseThemeDescriptor,
  preloadSingleReaderFont,
  resolveEffectiveBookAppearance,
  saveLocalBookAppearance,
  type LocalBookAppearance,
} from './readerAppearance';
import { useHighlights } from './useHighlights';
import { useSaveProgress, useServerProgress } from './useReaderProgress';
import './reader.css';
import './documentReader.css';

type EpubFlowMode = 'paginated' | 'scrolled';

interface PendingEpubSelection {
  cfi: string;
  text: string;
  chapterTitle: string;
  page: number;
  anchorRect: DOMRect;
}

interface SearchHit {
  cfi: string;
  excerpt: { pre?: string; match?: string; post?: string };
  label?: string;
}

function buildEpubStyles(fontId: string, themeId: string): string {
  const font = getReaderFont(fontId);
  const theme = getReaderTheme(themeId);
  const desc = parseThemeDescriptor(themeId);

  const hasCustomPaper = desc.themeId !== 'default';
  const hasCustomInk = Boolean(desc.inkColor && desc.inkColor !== 'auto');
  const paper = hasCustomPaper ? theme.paper : '#fcfbf7';
  const ink = hasCustomInk ? desc.inkColor : hasCustomPaper ? theme.ink : '#1f2328';
  const isDark = hasCustomPaper
    ? theme.isDark
    : hasCustomInk
      ? !isHexColorDark(desc.inkColor)
      : false;
  const linkColor = isDark ? '#7dd3fc' : '#2563eb';
  const fontScale = desc.fontScale || 100;
  const lineHeight = desc.lineHeight && desc.lineHeight !== 'default' ? desc.lineHeight : '1.68';
  const fontFamily =
    font.id !== 'default' && font.family
      ? font.family
      : '"Iowan Old Style", "Palatino Linotype", "Book Antiqua", Georgia, serif';

  return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
      color-scheme: ${isDark ? 'dark' : 'light'};
      background-color: ${paper} !important;
      color: ${ink} !important;
      font-size: ${Math.round(17 * (fontScale / 100))}px !important;
      -webkit-font-smoothing: antialiased;
    }
    body {
      background-color: ${paper} !important;
      color: ${ink} !important;
      font-family: ${fontFamily} !important;
      line-height: ${lineHeight} !important;
      text-align: justify;
      hyphens: auto;
      -webkit-hyphens: auto;
    }
    p, li, blockquote, dd, dt, div, span {
      font-family: ${fontFamily};
      line-height: ${lineHeight};
      color: inherit;
    }
    h1, h2, h3, h4, h5, h6 {
      font-family: ${fontFamily} !important;
      color: ${ink} !important;
      text-align: left;
      break-after: avoid;
    }
    a, a:visited {
      color: ${linkColor} !important;
    }
    pre, code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace !important;
      background: ${isDark ? 'rgba(255,255,255,0.08)' : 'rgba(15,23,42,0.06)'} !important;
      border-radius: 4px;
    }
    img, svg {
      max-width: 100% !important;
      height: auto !important;
    }
  `;
}

function injectFontIntoEpubDoc(doc: Document, fontId: string): void {
  const font = getReaderFont(fontId);
  const head = doc.head || doc.documentElement;
  if (!head) return;
  const existing = doc.getElementById('bilingual-epub-font-link') as HTMLLinkElement | null;
  if (font.id !== 'default' && font.googleFontUrl) {
    if (existing) {
      if (existing.href !== font.googleFontUrl) existing.href = font.googleFontUrl;
    } else {
      const link = doc.createElement('link');
      link.id = 'bilingual-epub-font-link';
      link.rel = 'stylesheet';
      link.href = font.googleFontUrl;
      head.appendChild(link);
    }
  } else {
    existing?.remove();
  }
}

export function EpubReaderView({ book }: { book: Book }) {
  const navigate = useNavigate();
  const toast = useToast();
  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);
  const updateBookState = useUpdateBookState();
  const updateBookAppearanceDefaults = useUpdateBookAppearanceDefaults();

  const local = useMemo(() => getLocalProgress(book.slug), [book.slug]);

  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [flowMode, setFlowMode] = useState<EpubFlowMode>('paginated');
  const [twoColumn, setTwoColumn] = useState<boolean>(() =>
    typeof window !== 'undefined' ? window.innerWidth >= 1080 : true,
  );

  const [toc, setToc] = useState<FoliateTocItem[]>([]);
  const [activeChapterHref, setActiveChapterHref] = useState<string>('');
  const [activeChapterTitle, setActiveChapterTitle] = useState<string>(book.title);
  const [fraction, setFraction] = useState<number>(() => local?.progression ?? 0);
  const [estimatedPage, setEstimatedPage] = useState<number>(() => Math.max(1, local?.page ?? 1));
  const [totalVirtualPages, setTotalVirtualPages] = useState<number>(() =>
    Math.max(1, book.pageCount || 1),
  );

  const [drawerOpen, setDrawerOpen] = useState(false);
  const [drawerTab, setDrawerTab] = useState<'toc' | 'search'>('toc');
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<SearchHit[]>([]);
  const [searching, setSearching] = useState(false);

  const [appearanceOpen, setAppearanceOpen] = useState(false);
  const [localAppearance, setLocalAppearance] = useState<LocalBookAppearance>(() =>
    getLocalBookAppearance(book.slug),
  );
  const [highlightsOpen, setHighlightsOpen] = useState(false);
  const [popover, setPopover] = useState<SelectionPopoverState | null>(null);
  const pendingSelectionRef = useRef<PendingEpubSelection | null>(null);

  const [chatOpen, setChatOpen] = useState<boolean>(() => readJSON(STORAGE_KEYS.chatOpen, false));
  const [chatWidth, setChatWidth] = useState<number>(
    () => parseInt(readString(STORAGE_KEYS.chatWidth) || '', 10) || 400,
  );
  const [settingsOpen, setSettingsOpen] = useState(false);

  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<FoliateViewElement | null>(null);
  const overlayerClsRef = useRef<typeof import('foliate-js/overlayer.js').Overlayer | null>(null);
  const highlightsRef = useRef<Highlight[]>([]);
  const currentCfiRef = useRef<string>(local?.locator ?? '');
  const currentVisibleTextRef = useRef<string>('');
  const activeChapterTitleRef = useRef<string>(book.title);
  const estimatedPageRef = useRef<number>(estimatedPage);
  const userNavigatedRef = useRef(false);
  const readyRef = useRef(false);
  const appliedServerRef = useRef(false);

  const saveProgress = useSaveProgress(book.slug);
  const { data: serverProgress, isFetching: progressFetching } = useServerProgress(book.slug);
  const { highlights, createDocumentHighlight, updateHighlight, deleteHighlight } = useHighlights(
    book.slug,
    estimatedPage,
  );
  highlightsRef.current = highlights;
  estimatedPageRef.current = estimatedPage;
  activeChapterTitleRef.current = activeChapterTitle;

  const resolvedAppearance = useMemo(
    () => resolveEffectiveBookAppearance(book, localAppearance),
    [book, localAppearance],
  );
  const effectiveFontId = resolvedAppearance.effectiveFontId;
  const effectiveThemeId = resolvedAppearance.effectiveThemeId;
  const hasUserAppearanceOverride =
    resolvedAppearance.hasUserFontOverride || resolvedAppearance.hasUserThemeOverride;
  const hasCustomAppearance = effectiveFontId !== 'default' || effectiveThemeId !== 'default';
  const effectiveFontRef = useRef(effectiveFontId);
  const effectiveThemeRef = useRef(effectiveThemeId);
  effectiveFontRef.current = effectiveFontId;
  effectiveThemeRef.current = effectiveThemeId;

  const currentPaperBg = useMemo(() => {
    const desc = parseThemeDescriptor(effectiveThemeId);
    if (desc.themeId === 'default') return '#fcfbf7';
    return getReaderTheme(effectiveThemeId).paper;
  }, [effectiveThemeId]);

  useEffect(() => {
    ensureHostVocaStyles();
    preloadSingleReaderFont(effectiveFontId);
    void syncVocaCards().catch(() => {});
  }, [effectiveFontId]);

  // Apply typography / theme / margins / flow to foliate-view
  const applyEpubAppearance = useCallback(() => {
    const view = viewRef.current;
    const renderer = view?.renderer;
    if (!renderer) return;

    const desc = parseThemeDescriptor(effectiveThemeRef.current);
    const marginOpt = PAGE_MARGIN_OPTIONS.find((m) => m.id === desc.pageMargin);
    const gapPct =
      marginOpt?.id === 'compact' ? '4%' : marginOpt?.id === 'wide' ? '9%' : '6%';

    renderer.setAttribute('flow', flowMode);
    renderer.setAttribute('gap', gapPct);
    renderer.setAttribute('max-inline-size', twoColumn && flowMode === 'paginated' ? '720px' : '820px');
    renderer.setAttribute('max-column-count', twoColumn && flowMode === 'paginated' ? '2' : '1');
    renderer.setStyles?.(buildEpubStyles(effectiveFontRef.current, effectiveThemeRef.current));

    for (const item of renderer.getContents?.() ?? []) {
      if (item.doc) {
        injectFontIntoEpubDoc(item.doc, effectiveFontRef.current);
      }
    }
  }, [flowMode, twoColumn]);

  useEffect(() => {
    applyEpubAppearance();
  }, [effectiveFontId, effectiveThemeId, flowMode, twoColumn, applyEpubAppearance]);

  // Sync saved EPUB highlights onto foliate-view Overlayer
  const syncAnnotationsToView = useCallback(async () => {
    const view = viewRef.current;
    if (!view || !readyRef.current) return;
    for (const hl of highlightsRef.current) {
      const anchor = parseHighlightAnchor(hl.anchorJson);
      if (anchor?.kind === 'epub' && anchor.cfi) {
        try {
          await view.addAnnotation({ value: anchor.cfi });
        } catch {
          /* ignore unresolvable legacy CFI */
        }
      }
    }
  }, []);

  useEffect(() => {
    void syncAnnotationsToView();
  }, [highlights, syncAnnotationsToView]);

  // Helper: translate a DOMRect inside a chapter iframe to host window coordinates
  const toHostRect = useCallback((doc: Document, localRect: DOMRect): DOMRect => {
    const frameEl = doc.defaultView?.frameElement as HTMLElement | null;
    if (!frameEl) return localRect;
    const frameBox = frameEl.getBoundingClientRect();
    return new DOMRect(
      frameBox.left + localRect.left,
      frameBox.top + localRect.top,
      localRect.width,
      localRect.height,
    );
  }, []);

  // Mount & open EPUB with foliate-js
  useEffect(() => {
    let cancelled = false;
    let viewEl: FoliateViewElement | null = null;

    setLoading(true);
    setLoadError(null);
    readyRef.current = false;

    void (async () => {
      try {
        const [viewMod, overlayerMod] = await Promise.all([
          import('foliate-js/view.js'),
          import('foliate-js/overlayer.js'),
        ]);
        if (cancelled) return;
        overlayerClsRef.current = overlayerMod.Overlayer;

        if (!customElements.get('foliate-view')) {
          customElements.define('foliate-view', viewMod.View);
        }

        const res = await apiFetch(`/books/${encodeURIComponent(book.slug)}/source`);
        if (!res.ok) {
          throw new Error(`Không tải được file EPUB (HTTP ${res.status})`);
        }
        const blob = await res.blob();
        if (cancelled) return;

        const file = new File([blob], `${book.slug}.epub`, { type: 'application/epub+zip' });
        const host = hostRef.current;
        if (!host) return;
        host.innerHTML = '';

        viewEl = document.createElement('foliate-view') as FoliateViewElement;
        host.appendChild(viewEl);
        viewRef.current = viewEl;

        viewEl.addEventListener('relocate', (ev) => {
          const detail = (ev as CustomEvent<FoliateLocation>).detail;
          if (!detail) return;
          const nextFraction = typeof detail.fraction === 'number' ? detail.fraction : 0;
          setFraction(nextFraction);
          if (detail.cfi) currentCfiRef.current = detail.cfi;
          if (detail.tocItem?.label) {
            setActiveChapterTitle(detail.tocItem.label.trim());
          }
          if (detail.tocItem?.href) {
            setActiveChapterHref(detail.tocItem.href);
          }

          const total = detail.location?.total || Math.max(1, book.pageCount || 1);
          const current =
            detail.location?.current != null
              ? Math.max(1, detail.location.current + 1)
              : Math.max(1, Math.round(nextFraction * total));
          setTotalVirtualPages(total);
          setEstimatedPage(current);

          // Extract currently visible text for AI Companion Context
          try {
            const visibleTxt = detail.range?.toString().replace(/\s+/g, ' ').trim();
            if (visibleTxt && visibleTxt.length > 20) {
              currentVisibleTextRef.current = visibleTxt.slice(0, 6000);
            } else {
              const activeDoc = viewEl?.renderer?.getContents()?.[0]?.doc;
              const fallback = activeDoc?.body?.innerText?.replace(/\s+/g, ' ').trim() || '';
              currentVisibleTextRef.current = fallback.slice(0, 6000);
            }
          } catch {
            /* ignore */
          }

          if (readyRef.current && userNavigatedRef.current) {
            saveProgress(current, 'en', undefined, {
              locator: detail.cfi || '',
              progression: nextFraction,
            });
          }
        });

        viewEl.addEventListener('load', (ev) => {
          const { doc, index } = (ev as CustomEvent<{ doc: Document; index: number }>).detail;
          if (!doc) return;
          injectFontIntoEpubDoc(doc, effectiveFontRef.current);

          doc.addEventListener('mousedown', () => {
            setPopover(null);
            removeVocaLookupPanel(document);
          });

          doc.addEventListener('mouseup', () => {
            window.setTimeout(() => {
              const sel = doc.defaultView?.getSelection();
              const text = sel?.toString().trim() || '';
              if (!sel || sel.isCollapsed || text.length < 1 || !viewEl) return;
              const range = sel.getRangeAt(0);
              try {
                const cfi = viewEl.getCFI(index, range);
                const hostRect = toHostRect(doc, range.getBoundingClientRect());
                pendingSelectionRef.current = {
                  cfi,
                  text,
                  chapterTitle: activeChapterTitleRef.current,
                  page: estimatedPageRef.current,
                  anchorRect: hostRect,
                };
                setPopover({ mode: 'create', text, rect: hostRect });
              } catch {
                /* ignore invalid range */
              }
            }, 15);
          });

          doc.addEventListener('keydown', (ke) => {
            if (ke.key === 'ArrowRight' || ke.key === 'PageDown') {
              ke.preventDefault();
              userNavigatedRef.current = true;
              void viewEl?.next();
            } else if (ke.key === 'ArrowLeft' || ke.key === 'PageUp') {
              ke.preventDefault();
              userNavigatedRef.current = true;
              void viewEl?.prev();
            }
          });
        });

        viewEl.addEventListener('draw-annotation', (ev) => {
          const { draw, annotation } = (
            ev as CustomEvent<{
              draw: (fn: unknown, opts?: unknown) => void;
              annotation: { value: string };
            }>
          ).detail;
          const OverlayerCls = overlayerClsRef.current;
          if (!OverlayerCls) return;
          const matching = highlightsRef.current.find((h) => {
            const parsed = parseHighlightAnchor(h.anchorJson);
            return parsed?.kind === 'epub' && parsed.cfi === annotation.value;
          });
          draw(OverlayerCls.highlight, { color: matching?.color || '#fde047' });
        });

        viewEl.addEventListener('create-overlay', () => {
          void syncAnnotationsToView();
        });

        viewEl.addEventListener('show-annotation', (ev) => {
          const { value, range } = (
            ev as CustomEvent<{ value: string; index: number; range: Range }>
          ).detail;
          const matching = highlightsRef.current.find((h) => {
            const parsed = parseHighlightAnchor(h.anchorJson);
            return parsed?.kind === 'epub' && parsed.cfi === value;
          });
          if (!matching || !range) return;
          const doc = range.startContainer.ownerDocument;
          if (!doc) return;
          const hostRect = toHostRect(doc, range.getBoundingClientRect());
          pendingSelectionRef.current = null;
          setPopover({
            mode: 'edit',
            text: matching.text,
            rect: hostRect,
            highlightId: matching.id,
            color: matching.color,
            note: matching.note,
          });
        });

        await viewEl.open(file);
        if (cancelled) return;

        setToc(viewEl.book?.toc ?? []);
        applyEpubAppearance();

        const startLocator = local?.locator || undefined;
        await viewEl.init({
          lastLocation: startLocator,
          showTextStart: !startLocator,
        });

        if (!cancelled) {
          readyRef.current = true;
          setLoading(false);
          void syncAnnotationsToView();
        }
      } catch (err) {
        if (!cancelled) {
          setLoadError(err instanceof Error ? err.message : 'Không thể mở sách EPUB.');
          setLoading(false);
        }
      }
    })();

    return () => {
      cancelled = true;
      readyRef.current = false;
      try {
        viewEl?.close();
      } catch {
        /* ignore */
      }
      viewRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.slug]);

  // Reconcile server progress once loaded
  useEffect(() => {
    if (appliedServerRef.current || !serverProgress || progressFetching || loading) return;
    appliedServerRef.current = true;
    if (userNavigatedRef.current) return;

    const resolution = resolveProgressOnOpen(local, serverProgress);
    if (resolution.action === 'adopt') {
      const targetCfi = resolution.progress.locator;
      const targetFrac = resolution.progress.progression;
      if (targetCfi && viewRef.current) {
        void viewRef.current.goTo(targetCfi);
      } else if (typeof targetFrac === 'number' && targetFrac > 0 && viewRef.current) {
        void viewRef.current.goToFraction(targetFrac);
      }
      saveLocalProgress(book.slug, {
        page: resolution.progress.page,
        viewMode: 'en',
        locator: targetCfi || '',
        progression: targetFrac ?? undefined,
        lastRead: resolution.lastReadMs,
      });
    } else if (resolution.action === 'pushLocal') {
      saveProgress(resolution.progress.page, 'en', resolution.lastReadMs, {
        locator: resolution.progress.locator,
        progression: resolution.progress.progression,
      });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverProgress, progressFetching, loading]);

  // Register AI Companion page context provider
  useEffect(() => {
    registerReaderPageContextProvider({
      getPageText: () => {
        const chapter = activeChapterTitleRef.current;
        const body = currentVisibleTextRef.current;
        if (!body) return '';
        return `=== EPUB (${chapter}) ===\n${body}`;
      },
      getSelectedText: () => {
        for (const c of viewRef.current?.renderer?.getContents() ?? []) {
          const sel = c.doc?.defaultView?.getSelection()?.toString().trim();
          if (sel) return `[Selected EPUB text]:\n${sel}`;
        }
        if (pendingSelectionRef.current?.text) {
          return `[Selected EPUB text]:\n${pendingSelectionRef.current.text}`;
        }
        return '';
      },
    });
    return () => registerReaderPageContextProvider(null);
  }, []);

  // Keyboard page navigation on host window
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
      const k = e.key.toLowerCase();
      if (e.key === 'ArrowLeft' || e.key === 'PageUp' || k === 'k') {
        e.preventDefault();
        userNavigatedRef.current = true;
        void viewRef.current?.prev();
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown' || k === 'j') {
        e.preventDefault();
        userNavigatedRef.current = true;
        void viewRef.current?.next();
      } else if (k === 'a' && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        setAppearanceOpen((v) => !v);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const handleSelectFont = useCallback(
    (fontId: string) => {
      preloadSingleReaderFont(fontId);
      const next: LocalBookAppearance = { readerFont: fontId, readerTheme: effectiveThemeId };
      saveLocalBookAppearance(book.slug, next);
      setLocalAppearance(next);
      updateBookState.mutate({
        slug: book.slug,
        patch: { readerFont: fontId, readerTheme: effectiveThemeId },
      });
    },
    [book.slug, effectiveThemeId, updateBookState],
  );

  const handleSelectTheme = useCallback(
    (themeDescriptor: string) => {
      const next: LocalBookAppearance = {
        readerFont: effectiveFontId,
        readerTheme: themeDescriptor,
      };
      saveLocalBookAppearance(book.slug, next);
      setLocalAppearance(next);
      updateBookState.mutate({
        slug: book.slug,
        patch: { readerFont: effectiveFontId, readerTheme: themeDescriptor },
      });
    },
    [book.slug, effectiveFontId, updateBookState],
  );

  const handleResetAppearance = useCallback(() => {
    const empty: LocalBookAppearance = { readerFont: '', readerTheme: '' };
    saveLocalBookAppearance(book.slug, empty);
    setLocalAppearance(empty);
    updateBookState.mutate({ slug: book.slug, patch: { readerFont: '', readerTheme: '' } });
  }, [book.slug, updateBookState]);

  const handleSaveAsBookDefault = useCallback(() => {
    updateBookAppearanceDefaults.mutate(
      { slug: book.slug, patch: { defaultFont: effectiveFontId, defaultTheme: effectiveThemeId } },
      {
        onSuccess: () => {
          const empty: LocalBookAppearance = { readerFont: '', readerTheme: '' };
          saveLocalBookAppearance(book.slug, empty);
          setLocalAppearance(empty);
          updateBookState.mutate({ slug: book.slug, patch: { readerFont: '', readerTheme: '' } });
          toast.show('Đã lưu giao diện mặc định cho sách EPUB này', 'success');
        },
        onError: () => toast.show('Không thể lưu giao diện mặc định', 'danger'),
      },
    );
  }, [book.slug, effectiveFontId, effectiveThemeId, toast, updateBookAppearanceDefaults, updateBookState]);

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
      const anchorJson = serializeHighlightAnchor({
        kind: 'epub',
        cfi: pending.cfi,
        chapterTitle: pending.chapterTitle,
      });
      createDocumentHighlight({
        page: pending.page,
        lang: 'epub',
        color,
        text: pending.text,
        anchorJson,
      });
      for (const c of viewRef.current?.renderer?.getContents() ?? []) {
        c.doc?.defaultView?.getSelection()?.removeAllRanges();
      }
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
      const anchorJson = serializeHighlightAnchor({
        kind: 'epub',
        cfi: pending.cfi,
        chapterTitle: pending.chapterTitle,
      });
      createDocumentHighlight({
        page: pending.page,
        lang: 'epub',
        color,
        text: pending.text,
        anchorJson,
        note,
      });
      for (const c of viewRef.current?.renderer?.getContents() ?? []) {
        c.doc?.defaultView?.getSelection()?.removeAllRanges();
      }
      pendingSelectionRef.current = null;
      setPopover(null);
    },
    [popover, createDocumentHighlight, updateHighlight],
  );

  const handleDeleteHighlight = useCallback(
    (id: string) => {
      const target = highlightsRef.current.find((h) => h.id === id);
      const anchor = parseHighlightAnchor(target?.anchorJson);
      deleteHighlight(id);
      if (anchor?.kind === 'epub' && anchor.cfi) {
        void viewRef.current?.deleteAnnotation({ value: anchor.cfi });
      }
    },
    [deleteHighlight],
  );

  const handleRunSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    const q = searchQuery.trim();
    if (!q || !viewRef.current) return;
    setSearching(true);
    setSearchResults([]);
    const hits: SearchHit[] = [];
    try {
      for await (const res of viewRef.current.search({ query: q })) {
        if (res.subitems?.length) {
          for (const sub of res.subitems) {
            hits.push({ cfi: sub.cfi, excerpt: sub.excerpt || {}, label: res.label });
            if (hits.length >= 60) break;
          }
        } else if (res.cfi) {
          hits.push({ cfi: res.cfi, excerpt: res.excerpt || {}, label: res.label });
        }
        if (hits.length >= 60) break;
      }
    } catch {
      /* ignore */
    }
    setSearchResults(hits);
    setSearching(false);
  };

  const toggleChat = () => {
    setChatOpen((v) => {
      const next = !v;
      writeJSON(STORAGE_KEYS.chatOpen, next);
      if (next) setHighlightsOpen(false);
      return next;
    });
  };

  const percent = Math.round(fraction * 100);

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
            title="Mục lục & Tìm kiếm"
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
              onClick={() => {
                userNavigatedRef.current = true;
                void viewRef.current?.prev();
              }}
              aria-label="Trang trước"
            >
              ‹
            </button>
            <span className="page-indicator" style={{ padding: '0 8px', fontSize: 12.5 }}>
              {percent}% · {estimatedPage}/{totalVirtualPages}
            </span>
            <button
              className="nav-btn page-nav__arrow"
              onClick={() => {
                userNavigatedRef.current = true;
                void viewRef.current?.next();
              }}
              aria-label="Trang sau"
            >
              ›
            </button>
          </div>
        </div>

        <div className="reader-topbar__right">
          {percent >= 95 && (
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

          <div className="doc-mode-group" title="Kiểu đọc EPUB">
            <button
              type="button"
              className={`doc-mode-btn ${flowMode === 'paginated' ? 'active' : ''}`}
              onClick={() => setFlowMode('paginated')}
            >
              Lật trang
            </button>
            <button
              type="button"
              className={`doc-mode-btn ${flowMode === 'scrolled' ? 'active' : ''}`}
              onClick={() => setFlowMode('scrolled')}
            >
              Cuộn dọc
            </button>
          </div>

          {flowMode === 'paginated' && (
            <div className="doc-mode-group" title="Số cột trang">
              <button
                type="button"
                className={`doc-mode-btn ${!twoColumn ? 'active' : ''}`}
                onClick={() => setTwoColumn(false)}
              >
                1 cột
              </button>
              <button
                type="button"
                className={`doc-mode-btn ${twoColumn ? 'active' : ''}`}
                onClick={() => setTwoColumn(true)}
              >
                2 cột
              </button>
            </div>
          )}

          <button
            className={`btn-icon btn-reader-appearance ${appearanceOpen ? 'active' : ''} ${hasCustomAppearance ? 'has-custom-appearance' : ''}`}
            onClick={() => setAppearanceOpen((v) => !v)}
            title="Tuỳ chỉnh Font & Màu giấy (A)"
          >
            <span className="reader-appearance-glyph" aria-hidden="true">
              Aa
            </span>
            {hasCustomAppearance && <span className="reader-appearance-dot" />}
          </button>

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

      {appearanceOpen && (
        <ReaderAppearancePopover
          bookTitle={book.title}
          effectiveFontId={effectiveFontId}
          effectiveThemeId={effectiveThemeId}
          bookDefaultFontId={resolvedAppearance.bookDefaultFontId}
          bookDefaultThemeId={resolvedAppearance.bookDefaultThemeId}
          hasUserOverride={hasUserAppearanceOverride}
          isSavingDefault={updateBookAppearanceDefaults.isPending}
          appliedFontScale={parseThemeDescriptor(effectiveThemeId).fontScale || 100}
          clampedByA4={false}
          atMaxA4Scale={false}
          onSelectFont={handleSelectFont}
          onSelectTheme={handleSelectTheme}
          onResetToBookDefault={handleResetAppearance}
          onSaveAsBookDefault={handleSaveAsBookDefault}
          onClose={() => setAppearanceOpen(false)}
        />
      )}

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
                className={`doc-nav-drawer__tab ${drawerTab === 'search' ? 'is-active' : ''}`}
                onClick={() => setDrawerTab('search')}
              >
                Tìm kiếm
              </button>
            </div>
            <button className="nav-btn" onClick={() => setDrawerOpen(false)} aria-label="Đóng">
              ✕
            </button>
          </div>

          <div className="doc-nav-drawer__body">
            {drawerTab === 'toc' ? (
              toc.length === 0 ? (
                <div className="doc-drawer-empty">Sách EPUB này không khai báo mục lục.</div>
              ) : (
                <EpubTocTree
                  items={toc}
                  activeHref={activeChapterHref}
                  level={0}
                  onSelect={(href) => {
                    userNavigatedRef.current = true;
                    void viewRef.current?.goTo(href);
                  }}
                />
              )
            ) : (
              <div>
                <form className="doc-search-form" onSubmit={(e) => void handleRunSearch(e)}>
                  <input
                    className="doc-search-input"
                    type="search"
                    placeholder="Tìm từ hoặc cụm từ..."
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                  />
                  <button type="submit" className="doc-mode-btn active" disabled={searching}>
                    {searching ? '…' : 'Tìm'}
                  </button>
                </form>
                {searchResults.length === 0 ? (
                  <div className="doc-drawer-empty">
                    {searching ? 'Đang tìm kiếm…' : 'Nhập từ khóa để tìm trong toàn cuốn sách.'}
                  </div>
                ) : (
                  searchResults.map((hit, i) => (
                    <button
                      key={`${hit.cfi}-${i}`}
                      type="button"
                      className="doc-search-result"
                      onClick={() => {
                        userNavigatedRef.current = true;
                        void viewRef.current?.goTo(hit.cfi);
                      }}
                    >
                      {hit.label && (
                        <div style={{ fontSize: 11, opacity: 0.7, marginBottom: 3 }}>
                          {hit.label}
                        </div>
                      )}
                      <span>{hit.excerpt.pre}</span>
                      <mark>{hit.excerpt.match}</mark>
                      <span>{hit.excerpt.post}</span>
                    </button>
                  ))
                )}
              </div>
            )}
          </div>
        </aside>

        <div className="doc-reader-main">
          <div className="epub-stage-wrapper" style={{ backgroundColor: currentPaperBg }}>
            {flowMode === 'paginated' && (
              <>
                <button
                  type="button"
                  className="epub-turn-zone is-prev"
                  aria-label="Trang trước"
                  onClick={() => {
                    userNavigatedRef.current = true;
                    void viewRef.current?.prev();
                  }}
                >
                  ‹
                </button>
                <button
                  type="button"
                  className="epub-turn-zone is-next"
                  aria-label="Trang sau"
                  onClick={() => {
                    userNavigatedRef.current = true;
                    void viewRef.current?.next();
                  }}
                >
                  ›
                </button>
              </>
            )}

            <div ref={hostRef} className="epub-view-host" />

            {loading && (
              <div className="doc-status-overlay">
                <div className="doc-spinner" />
                <span>Đang mở sách EPUB…</span>
              </div>
            )}
            {loadError && (
              <div className="doc-status-overlay">
                <strong>Không thể mở sách EPUB</strong>
                <span>{loadError}</span>
              </div>
            )}
          </div>

          <div className="doc-bottom-bar">
            <span className="doc-bottom-bar__chapter" title={activeChapterTitle}>
              {activeChapterTitle}
            </span>
            <input
              type="range"
              className="doc-bottom-bar__slider"
              min={0}
              max={1000}
              value={Math.round(fraction * 1000)}
              onChange={(e) => {
                const f = Math.max(0, Math.min(1, parseInt(e.target.value, 10) / 1000));
                userNavigatedRef.current = true;
                setFraction(f);
                void viewRef.current?.goToFraction(f);
              }}
              aria-label="Thanh tiến độ đọc EPUB"
            />
            <span className="doc-bottom-bar__meta">{percent}%</span>
          </div>
        </div>

        <HighlightsSidebar
          open={highlightsOpen}
          currentPage={estimatedPage}
          highlights={highlights}
          bookFormat="epub"
          onOpenReference={(hl) => {
            const anchor = parseHighlightAnchor(hl.anchorJson);
            if (anchor?.kind === 'epub' && anchor.cfi) {
              userNavigatedRef.current = true;
              void viewRef.current?.goTo(anchor.cfi);
            }
          }}
          onDeleteHighlight={handleDeleteHighlight}
          onClose={() => setHighlightsOpen(false)}
        />

        <ChatSidebar
          book={book}
          page={estimatedPage}
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
                  handleDeleteHighlight(popover.highlightId!);
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

function EpubTocTree({
  items,
  activeHref,
  level,
  onSelect,
}: {
  items: FoliateTocItem[];
  activeHref: string;
  level: number;
  onSelect: (href: string) => void;
}) {
  return (
    <ul className="doc-toc-list">
      {items.map((item, idx) => (
        <li key={`${item.href}-${idx}`}>
          <button
            type="button"
            className={`doc-toc-item ${item.href && item.href === activeHref ? 'is-active' : ''}`}
            style={{ paddingLeft: `${10 + Math.min(level, 4) * 14}px` }}
            onClick={() => item.href && onSelect(item.href)}
          >
            <span>{item.label?.trim() || 'Chương'}</span>
          </button>
          {item.subitems && item.subitems.length > 0 && (
            <EpubTocTree
              items={item.subitems}
              activeHref={activeHref}
              level={level + 1}
              onSelect={onSelect}
            />
          )}
        </li>
      ))}
    </ul>
  );
}
