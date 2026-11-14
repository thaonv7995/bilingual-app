import { useCallback, useEffect, useRef, useState } from 'react';
import {
  playPageAudio,
  prefetchAudio,
  stopCurrentAudio,
  pauseCurrentAudio,
  resumeCurrentAudio,
  seekAudio,
  getAudioDuration,
  getCurrentAudioElement,
} from './audiobookService';
import {
  updateMediaSessionMetadata,
  updateMediaSessionPositionState,
  setMediaSessionPlaybackState,
  setupMediaSessionActionHandlers,
} from './mediaSession';
import { useServerSecrets } from '@/features/settings/serverSecrets';
import { segmentDocSentences } from '../reader/iframe/segmentation';
import { apiFetch } from '@/lib/api-client';

export type AudiobookLanguageMode = 'en' | 'vi';

export interface SentenceItem {
  id: string;
  text: string;
  lang: 'en' | 'vi';
}

interface UseAudiobookOptions {
  bookSlug?: string;
  currentPage: number;
  totalPage: number;
  viewMode: 'en' | 'vi' | 'split';
  enIframeRef: React.RefObject<HTMLIFrameElement | null>;
  viIframeRef: React.RefObject<HTMLIFrameElement | null>;
  enabled?: boolean;
  onNextPage: () => void;
  onPrevPage?: () => void;
}

export function useAudiobook({
  bookSlug,
  currentPage,
  totalPage,
  viewMode,
  enIframeRef,
  viIframeRef,
  enabled = true,
  onNextPage,
  onPrevPage,
}: UseAudiobookOptions) {
  const { data: serverSecrets } = useServerSecrets();
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentSentenceIndex, setCurrentSentenceIndex] = useState(0);
  const [sentences, setSentences] = useState<SentenceItem[]>([]);
  const [mode, setMode] = useState<AudiobookLanguageMode>('en');
  const [speed, setSpeed] = useState<string>(() => serverSecrets?.speechSpeed || '1.0');
  const [autoPageTurn, setAutoPageTurn] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const playingRef = useRef(false);
  const currentSentenceIndexRef = useRef(0);
  const shouldAutoPlayNextPageRef = useRef<boolean>(false);
  const cumulativeOffsetsRef = useRef<number[]>([]);
  const totalCharsRef = useRef<number>(0);
  const activePageRef = useRef<number>(currentPage);
  const previousPageRef = useRef<number>(currentPage);
  activePageRef.current = currentPage;

  // In-memory cache for parsed page sentences, keyed by `${page}:${mode}`
  const pageSentencesCacheRef = useRef<Map<string, SentenceItem[]>>(new Map());

  // Sync speed with server settings when loaded
  useEffect(() => {
    if (serverSecrets?.speechSpeed) {
      setSpeed(serverSecrets.speechSpeed);
    }
  }, [serverSecrets?.speechSpeed]);

  // Extract sentences from an iframe document with multi-tier fallback
  const getDocSentences = useCallback((iframe: HTMLIFrameElement | null, lang: 'en' | 'vi'): SentenceItem[] => {
    if (!iframe || !iframe.contentDocument) return [];
    const doc = iframe.contentDocument;

    const excludedSelector = [
      'script',
      'style',
      'noscript',
      'template',
      'head',
      'nav',
      'footer',
      '.book-footer',
      '.running-header',
      '[hidden]',
      '[aria-hidden="true"]',
      '[data-audiobook-ignore="true"]',
    ].join(',');

    const isReadable = (element: HTMLElement): boolean => {
      if (element.closest(excludedSelector)) return false;

      const style = iframe.contentWindow?.getComputedStyle(element);
      if (style) {
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        if (Number(style.opacity) === 0) return false;
      }

      return element.getClientRects().length > 0;
    };

    const orderedListMarker = (element: HTMLElement): string => {
      if (element.tagName !== 'LI') return '';

      const list = element.parentElement;
      if (!list || list.tagName !== 'OL') return '';

      const explicitValue = Number.parseInt(element.getAttribute('value') || '', 10);
      if (Number.isFinite(explicitValue)) return `${explicitValue}. `;

      const siblings = Array.from(list.children).filter((child) => child.tagName === 'LI');
      const index = siblings.indexOf(element);
      const reversed = list.hasAttribute('reversed');
      const parsedStart = Number.parseInt(list.getAttribute('start') || '', 10);
      const start = Number.isFinite(parsedStart)
        ? parsedStart
        : reversed
          ? siblings.length
          : 1;
      const number = reversed ? start - index : start + index;

      return `${number}. `;
    };

    const visibleText = (element: HTMLElement): string => {
      const text = (element.innerText || '')
        .replace(/\s+/g, ' ')
        .trim();
      return `${orderedListMarker(element)}${text}`;
    };

    let nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node')).filter(isReadable);
    if (nodes.length === 0) {
      try {
        segmentDocSentences(doc);
        nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node')).filter(isReadable);
      } catch {
        /* ignore fallback errors */
      }
    }

    if (nodes.length === 0) {
      // Fallback: collect all readable semantic content from the visible book
      // container. This includes definition lists, tables, captions and code
      // blocks that were previously omitted from audiobook narration.
      const root =
        doc.querySelector<HTMLElement>('article') ||
        doc.querySelector<HTMLElement>('main') ||
        doc.body;
      const pars = Array.from(
        root.querySelectorAll<HTMLElement>(
          'p, h1, h2, h3, h4, h5, h6, li, blockquote, dt, dd, figcaption, th, td, pre, .chapter-start, .section-title, .action-header, .action-title',
        ),
      ).filter(isReadable);
      return pars
        .map((p, idx) => {
          if (!p.dataset.sentenceId) {
            p.dataset.sentenceId = `fallback-${lang}-s-${idx}`;
            p.classList.add('sentence-node');
          }
          return {
            id: p.dataset.sentenceId,
            text: visibleText(p),
            lang,
          };
        })
        .filter((item) => item.text.length > 0);
    }

    return nodes
      .map((node) => ({
        id: node.dataset.sentenceId || '',
        text: visibleText(node),
        lang,
      }))
      .filter((item) => item.text.length > 0);
  }, []);

  // Background-safe direct fetch for sentence extraction
  const fetchSentencesDirectly = useCallback(
    async (page: number, targetMode: AudiobookLanguageMode): Promise<SentenceItem[]> => {
      if (!bookSlug) return [];
      const cacheKey = `${page}:${targetMode}`;
      const cached = pageSentencesCacheRef.current.get(cacheKey);
      if (cached && cached.length > 0) return cached;

      try {
        const pad = String(page).padStart(4, '0');
        const url = `/books/${encodeURIComponent(bookSlug)}/output/${targetMode}/page_${pad}.html`;
        const res = await apiFetch(url);
        if (!res.ok) return [];
        const html = await res.text();
        const doc = new DOMParser().parseFromString(html, 'text/html');

        doc
          .querySelectorAll(
            'script, style, noscript, template, head, nav, footer, .book-footer, .running-header, [hidden], [aria-hidden="true"], [data-audiobook-ignore="true"]',
          )
          .forEach((element) => element.remove());

        const root =
          doc.querySelector<HTMLElement>('article') ||
          doc.querySelector<HTMLElement>('main') ||
          doc.body;

        let nodes = Array.from(root.querySelectorAll<HTMLElement>('.sentence-node'));
        if (nodes.length === 0) {
          nodes = Array.from(
            root.querySelectorAll<HTMLElement>(
              'p, h1, h2, h3, h4, h5, h6, li, blockquote, dt, dd, figcaption, th, td, pre, .chapter-start, .section-title, .action-header, .action-title',
            ),
          );
        }
        const items = nodes
          .map((n, idx) => ({
            id: n.dataset?.sentenceId || `fallback-${targetMode}-s-${idx}`,
            text: (() => {
              const content = (n.textContent || '').replace(/\s+/g, ' ').trim();
              if (n.tagName !== 'LI' || n.parentElement?.tagName !== 'OL') {
                return content;
              }

              const list = n.parentElement;
              const explicitValue = Number.parseInt(n.getAttribute('value') || '', 10);
              if (Number.isFinite(explicitValue)) {
                return `${explicitValue}. ${content}`;
              }

              const siblings = Array.from(list.children).filter(
                (child) => child.tagName === 'LI',
              );
              const itemIndex = siblings.indexOf(n);
              const reversed = list.hasAttribute('reversed');
              const parsedStart = Number.parseInt(list.getAttribute('start') || '', 10);
              const start = Number.isFinite(parsedStart)
                ? parsedStart
                : reversed
                  ? siblings.length
                  : 1;
              const number = reversed ? start - itemIndex : start + itemIndex;

              return `${number}. ${content}`;
            })(),
            lang: targetMode,
          }))
          .filter((item) => item.text.length > 0);

        if (items.length > 0) {
          pageSentencesCacheRef.current.set(cacheKey, items);
        }
        return items;
      } catch {
        return [];
      }
    },
    [bookSlug],
  );

  // Extract sentences for selected mode (en or vi)
  const extractSentencesForMode = useCallback(
    (targetMode: AudiobookLanguageMode): SentenceItem[] => {
      const enList = getDocSentences(enIframeRef.current, 'en');
      const viList = getDocSentences(viIframeRef.current, 'vi');

      if (targetMode === 'en') {
        return enList.length > 0 ? enList : viList.map((item) => ({ ...item, lang: 'en' as const }));
      } else {
        return viList.length > 0 ? viList : enList.map((item) => ({ ...item, lang: 'vi' as const }));
      }
    },
    [getDocSentences, enIframeRef, viIframeRef],
  );

  // Calculate character offsets for accurate sentence time mapping
  const updateSentenceOffsets = useCallback((items: SentenceItem[]) => {
    const charLengths = items.map((s) => Math.max(1, s.text.length));
    const total = charLengths.reduce((acc, len) => acc + len, 0);
    const offsets: number[] = [];
    let running = 0;
    for (const len of charLengths) {
      offsets.push(running);
      running += len;
    }
    cumulativeOffsetsRef.current = offsets;
    totalCharsRef.current = total;
  }, []);

  // Update Media Session Lock Screen information
  const updateMediaInfo = useCallback(
    (index: number, list: SentenceItem[]) => {
      const item = list[index];
      const text = item?.text || '';
      const title = text ? text : `Trang ${currentPage}`;
      const artist = `Bilingual Reader (${mode.toUpperCase()})`;
      const album = bookSlug ? `${bookSlug} • Trang ${currentPage}/${totalPage}` : `Trang ${currentPage}`;

      updateMediaSessionMetadata({
        title,
        artist,
        album,
      });
    },
    [bookSlug, currentPage, mode, totalPage],
  );

  // Highlight and scroll sentence in iframes
  const highlightSentence = useCallback(
    (sentenceId: string | null, targetLang?: 'en' | 'vi') => {
      const applyToDoc = (iframe: HTMLIFrameElement | null) => {
        if (!iframe || !iframe.contentDocument) return;
        const doc = iframe.contentDocument;
        doc.querySelectorAll('.sentence-node.highlight-sync').forEach((el) => {
          el.classList.remove('highlight-sync');
        });
        if (sentenceId) {
          const target = doc.querySelector<HTMLElement>(`.sentence-node[data-sentence-id="${sentenceId}"]`);
          if (target) {
            target.classList.add('highlight-sync');
            target.scrollIntoView({ behavior: 'smooth', block: 'center' });
          }
        }
      };

      if (!targetLang || targetLang === 'en') {
        applyToDoc(enIframeRef.current);
      }
      if (!targetLang || targetLang === 'vi') {
        applyToDoc(viIframeRef.current);
      }
    },
    [enIframeRef, viIframeRef],
  );

  // Background prefetch for next page sentences and EXACT matching audio
  const prefetchNextPageAudio = useCallback(
    async (nextPage: number, nextMode: AudiobookLanguageMode) => {
      if (nextPage > totalPage || !bookSlug) return;
      try {
        const pad = String(nextPage).padStart(4, '0');
        const url = `/books/${encodeURIComponent(bookSlug)}/output/${nextMode}/page_${pad}.html`;
        const res = await apiFetch(url);
        if (!res.ok) return;
        const html = await res.text();
        const doc = new DOMParser().parseFromString(html, 'text/html');
        let nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node'));
        if (nodes.length === 0) {
          nodes = Array.from(
            doc.querySelectorAll<HTMLElement>(
              'p, h1, h2, h3, h4, h5, h6, li, blockquote, .chapter-start, .section-title, .action-header, .action-title',
            ),
          );
        }
        const items = nodes
          .map((n, idx) => ({
            id: n.dataset?.sentenceId || `fallback-${nextMode}-s-${idx}`,
            text: n.textContent?.trim() || '',
            lang: nextMode,
          }))
          .filter((t) => t.text.length > 0);

        if (items.length === 0) return;
        pageSentencesCacheRef.current.set(`${nextPage}:${nextMode}`, items);

        // Exact text match for prefetch
        const text = items.map((s) => s.text).join(' ');
        if (!text) return;

        const provider = serverSecrets?.audioProvider || 'device';
        if (provider === 'device') return;
        const isVi = nextMode === 'vi';
        const langTag = isVi ? 'vi-VN' : 'en-US';
        const voice = isVi
          ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : (serverSecrets?.audioVoice && serverSecrets.audioVoice !== '21m00Tcm4TlvDq8ikWAM' && !serverSecrets.audioVoice.startsWith('en-') ? serverSecrets.audioVoice : '')))
          : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));

        await prefetchAudio({
          text,
          provider,
          voice,
          speed,
          lang: langTag,
        });
      } catch (err) {
        console.warn('[Audiobook] Next page prefetch error:', err);
      }
    },
    [bookSlug, totalPage, serverSecrets, speed],
  );

  // Atomic mode change: cleanly stop audio, switch mode, re-extract, and reset index
  const changeMode = useCallback(
    (newMode: AudiobookLanguageMode) => {
      shouldAutoPlayNextPageRef.current = false;
      playingRef.current = false;
      setIsPlaying(false);
      stopCurrentAudio();
      setMediaSessionPlaybackState('paused');
      highlightSentence(null);

      setMode(newMode);
      currentSentenceIndexRef.current = 0;
      setCurrentSentenceIndex(0);
      setError(null);
      pageSentencesCacheRef.current.clear();

      const list = extractSentencesForMode(newMode);
      setSentences(list);
      updateSentenceOffsets(list);
      if (list[0]) {
        highlightSentence(list[0].id, list[0].lang);
        updateMediaInfo(0, list);
      }
    },
    [extractSentencesForMode, highlightSentence, updateSentenceOffsets, updateMediaInfo],
  );

  // Play full page audio
  const startFullPagePlayback = useCallback(
    async (startIndex: number, currentList: SentenceItem[]) => {
      if (currentList.length === 0) {
        setError('Không tìm thấy nội dung văn bản trên trang này.');
        setIsPlaying(false);
        playingRef.current = false;
        setMediaSessionPlaybackState('none');
        return;
      }

      setIsPlaying(true);
      playingRef.current = true;
      setError(null);
      setMediaSessionPlaybackState('playing');
      updateMediaInfo(startIndex, currentList);

      const pageText = currentList.map((s) => s.text).join(' ');
      const provider = serverSecrets?.audioProvider || 'device';
      const isVi = mode === 'vi';
      const langTag = isVi ? 'vi-VN' : 'en-US';
      const voice = isVi
        ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : (serverSecrets?.audioVoice && serverSecrets.audioVoice !== '21m00Tcm4TlvDq8ikWAM' && !serverSecrets.audioVoice.startsWith('en-') ? serverSecrets.audioVoice : '')))
        : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));

      // Prefetch NEXT page audio in the background immediately
      prefetchNextPageAudio(currentPage + 1, mode);

      try {
        let hasInitialSeek = false;
        await playPageAudio(
          {
            text: pageText,
            provider,
            voice,
            speed,
            lang: langTag,
          },
          (currentTime, duration) => {
            if (!playingRef.current) return;
            const totalChars = totalCharsRef.current;
            const offsets = cumulativeOffsetsRef.current;
            if (!duration || duration <= 0 || totalChars <= 0) return;

            // Sync position state with Lock Screen / Control Center
            updateMediaSessionPositionState({
              duration,
              position: currentTime,
              playbackRate: parseFloat(speed) || 1.0,
            });

            // If playback started at an offset sentence, perform initial seek once metadata is ready
            if (!hasInitialSeek && startIndex > 0 && offsets.length > startIndex) {
              hasInitialSeek = true;
              const targetOffset = offsets[startIndex] || 0;
              const targetTime = (targetOffset / totalChars) * duration;
              seekAudio(targetTime);
              return;
            }

            const currentFraction = Math.min(1, Math.max(0, currentTime / duration));
            const currentChar = currentFraction * totalChars;

            let activeIdx = 0;
            for (let i = 0; i < offsets.length; i++) {
              if (currentChar >= offsets[i]!) {
                activeIdx = i;
              } else {
                break;
              }
            }

            if (activeIdx !== currentSentenceIndexRef.current) {
              currentSentenceIndexRef.current = activeIdx;
              setCurrentSentenceIndex(activeIdx);
              const item = currentList[activeIdx];
              if (item) {
                highlightSentence(item.id, item.lang);
                updateMediaInfo(activeIdx, currentList);
              }
            }
          },
        );

        if (!playingRef.current) return;

        // Page audio completed
        if (autoPageTurn && currentPage < totalPage) {
          const nextPage = currentPage + 1;
          const cachedNext = pageSentencesCacheRef.current.get(`${nextPage}:${mode}`);

          // Zero-gap instant transition if already cached
          if (cachedNext && cachedNext.length > 0) {
            onNextPage();
            currentSentenceIndexRef.current = 0;
            setCurrentSentenceIndex(0);
            setSentences(cachedNext);
            updateSentenceOffsets(cachedNext);
            startFullPagePlayback(0, cachedNext);
            return;
          }

          shouldAutoPlayNextPageRef.current = true;
          onNextPage();
        } else {
          setIsPlaying(false);
          playingRef.current = false;
          setMediaSessionPlaybackState('paused');
          highlightSentence(null);
        }
      } catch (err: unknown) {
        if (!playingRef.current) return;
        console.error('[Audiobook] Playback error:', err);
        setError(err instanceof Error ? err.message : 'Lỗi phát âm thanh');
        setIsPlaying(false);
        playingRef.current = false;
        setMediaSessionPlaybackState('paused');
      }
    },
    [
      serverSecrets,
      mode,
      prefetchNextPageAudio,
      currentPage,
      speed,
      autoPageTurn,
      totalPage,
      onNextPage,
      highlightSentence,
      updateMediaInfo,
      updateSentenceOffsets,
    ],
  );

  // Play / Resume
  const play = useCallback(() => {
    if (!enabled) return;
    let list = sentences;
    if (list.length === 0) {
      list = extractSentencesForMode(mode);
      setSentences(list);
      updateSentenceOffsets(list);
    }
    if (list.length === 0) {
      setError('Không tìm thấy nội dung văn bản trên trang này.');
      return;
    }

    const audioEl = getCurrentAudioElement();
    if (audioEl && !audioEl.ended && audioEl.src) {
      // Resume existing paused audio
      setIsPlaying(true);
      playingRef.current = true;
      setMediaSessionPlaybackState('playing');
      updateMediaInfo(currentSentenceIndexRef.current, list);
      resumeCurrentAudio().catch((err) => {
        console.warn('[Audiobook] Resume failed, restarting:', err);
        startFullPagePlayback(currentSentenceIndexRef.current, list);
      });
      return;
    }

    startFullPagePlayback(currentSentenceIndexRef.current, list);
  }, [enabled, sentences, extractSentencesForMode, mode, updateSentenceOffsets, startFullPagePlayback, updateMediaInfo]);

  // Pause
  const pause = useCallback(() => {
    shouldAutoPlayNextPageRef.current = false;
    setIsPlaying(false);
    playingRef.current = false;
    setMediaSessionPlaybackState('paused');
    pauseCurrentAudio();
  }, []);

  // Seek to specific sentence index
  const seekToSentence = useCallback(
    (targetIdx: number) => {
      if (sentences.length === 0) return;
      const clamped = Math.max(0, Math.min(sentences.length - 1, targetIdx));
      currentSentenceIndexRef.current = clamped;
      setCurrentSentenceIndex(clamped);
      const item = sentences[clamped];
      if (item) {
        highlightSentence(item.id, item.lang);
        updateMediaInfo(clamped, sentences);
      }

      const duration = getAudioDuration();
      const totalChars = totalCharsRef.current;
      const offsets = cumulativeOffsetsRef.current;
      if (duration > 0 && totalChars > 0 && offsets.length > clamped) {
        const targetOffset = offsets[clamped] || 0;
        const targetTime = (targetOffset / totalChars) * duration;
        seekAudio(targetTime);
      } else if (isPlaying) {
        // Audio not yet loaded or device TTS, restart from target index
        stopCurrentAudio();
        startFullPagePlayback(clamped, sentences);
      }
    },
    [sentences, highlightSentence, updateMediaInfo, isPlaying, startFullPagePlayback],
  );

  const nextSentence = useCallback(() => {
    if (currentSentenceIndexRef.current < sentences.length - 1) {
      seekToSentence(currentSentenceIndexRef.current + 1);
    } else if (autoPageTurn && currentPage < totalPage) {
      const nextPage = currentPage + 1;
      const cachedNext = pageSentencesCacheRef.current.get(`${nextPage}:${mode}`);
      if (cachedNext && cachedNext.length > 0) {
        onNextPage();
        currentSentenceIndexRef.current = 0;
        setCurrentSentenceIndex(0);
        setSentences(cachedNext);
        updateSentenceOffsets(cachedNext);
        startFullPagePlayback(0, cachedNext);
        return;
      }
      shouldAutoPlayNextPageRef.current = true;
      onNextPage();
    }
  }, [
    seekToSentence,
    sentences.length,
    autoPageTurn,
    currentPage,
    totalPage,
    mode,
    onNextPage,
    updateSentenceOffsets,
    startFullPagePlayback,
  ]);

  const prevSentence = useCallback(() => {
    if (currentSentenceIndexRef.current > 0) {
      seekToSentence(currentSentenceIndexRef.current - 1);
    } else if (onPrevPage && currentPage > 1) {
      onPrevPage();
    }
  }, [seekToSentence, onPrevPage, currentPage]);

  // Connect Web MediaSession action handlers (Lock Screen & Media Key controls)
  useEffect(() => {
    if (!enabled) return;
    setupMediaSessionActionHandlers({
      onPlay: () => play(),
      onPause: () => pause(),
      onNextTrack: () => nextSentence(),
      onPreviousTrack: () => prevSentence(),
      onSeekTo: (timeSeconds) => seekAudio(timeSeconds),
      onSkipForward: () => nextSentence(),
      onSkipBackward: () => prevSentence(),
    });
  }, [enabled, play, pause, nextSentence, prevSentence]);

  // Re-extract sentences when page or viewMode changes, and auto-continue playback on page change
  useEffect(() => {
    let cancelled = false;
    const pageChanged = previousPageRef.current !== currentPage;
    const shouldContinueOnNewPage = shouldAutoPlayNextPageRef.current;
    previousPageRef.current = currentPage;

    // A page changed directly from the reader controls must never keep playing
    // audio synthesized for the previous page. Automatic audiobook page turns
    // are the only page transition allowed to continue playback.
    if (pageChanged && !shouldContinueOnNewPage) {
      if (playingRef.current) {
        playingRef.current = false;
        setIsPlaying(false);
        stopCurrentAudio();
        setMediaSessionPlaybackState('paused');
        highlightSentence(null);
      }
      currentSentenceIndexRef.current = 0;
      setCurrentSentenceIndex(0);
    }

    // Do not scan DOM or re-fetch HTML on every page turn while Audiobook bar is closed.
    if (!enabled && !playingRef.current && !shouldContinueOnNewPage) {
      return;
    }

    // Check memory cache first
    const cached = pageSentencesCacheRef.current.get(`${currentPage}:${mode}`);
    if (cached && cached.length > 0) {
      setSentences(cached);
      updateSentenceOffsets(cached);
      if (shouldAutoPlayNextPageRef.current) {
        shouldAutoPlayNextPageRef.current = false;
        currentSentenceIndexRef.current = 0;
        setCurrentSentenceIndex(0);
        startFullPagePlayback(0, cached);
      }
      return;
    }

    const timer = setTimeout(async () => {
      let extracted = extractSentencesForMode(mode);
      if (extracted.length === 0 && bookSlug) {
        extracted = await fetchSentencesDirectly(currentPage, mode);
      }
      if (cancelled) return;

      setSentences(extracted);
      updateSentenceOffsets(extracted);

      if (shouldAutoPlayNextPageRef.current) {
        shouldAutoPlayNextPageRef.current = false;
        if (extracted.length > 0) {
          currentSentenceIndexRef.current = 0;
          setCurrentSentenceIndex(0);
          startFullPagePlayback(0, extracted);
        }
      } else if (currentSentenceIndexRef.current >= extracted.length) {
        currentSentenceIndexRef.current = 0;
        setCurrentSentenceIndex(0);
      }
    }, 100);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [
    enabled,
    currentPage,
    viewMode,
    mode,
    extractSentencesForMode,
    updateSentenceOffsets,
    startFullPagePlayback,
    bookSlug,
    fetchSentencesDirectly,
    highlightSentence,
  ]);

  // Clean up on unmount
  useEffect(() => {
    return () => {
      playingRef.current = false;
      stopCurrentAudio();
      setMediaSessionPlaybackState('none');
      highlightSentence(null);
    };
  }, [highlightSentence]);

  useEffect(() => {
    if (!enabled) {
      shouldAutoPlayNextPageRef.current = false;
      if (playingRef.current) {
        playingRef.current = false;
        setIsPlaying(false);
        stopCurrentAudio();
        setMediaSessionPlaybackState('none');
        highlightSentence(null);
      }
    }
  }, [enabled, highlightSentence]);

  return {
    isPlaying,
    currentSentenceIndex,
    totalSentences: sentences.length,
    currentSentence: sentences[currentSentenceIndex] || null,
    mode,
    setMode: changeMode,
    changeMode,
    speed,
    setSpeed,
    autoPageTurn,
    setAutoPageTurn,
    error,
    play,
    pause,
    nextSentence,
    prevSentence,
    provider: serverSecrets?.audioProvider || 'device',
  };
}
