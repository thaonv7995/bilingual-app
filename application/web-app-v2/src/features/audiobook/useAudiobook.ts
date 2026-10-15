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
  onNextPage,
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
  activePageRef.current = currentPage;

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

    let nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node'));
    if (nodes.length === 0) {
      try {
        segmentDocSentences(doc);
        nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node'));
      } catch {
        /* ignore fallback errors */
      }
    }

    if (nodes.length === 0) {
      // Fallback: collect paragraphs and headings
      const pars = Array.from(
        doc.querySelectorAll<HTMLElement>(
          'p, h1, h2, h3, h4, h5, h6, li, blockquote, .chapter-start, .section-title, .action-header, .action-title',
        ),
      );
      return pars
        .map((p, idx) => {
          if (!p.dataset.sentenceId) {
            p.dataset.sentenceId = `fallback-${lang}-s-${idx}`;
            p.classList.add('sentence-node');
          }
          return {
            id: p.dataset.sentenceId,
            text: p.textContent?.trim() || '',
            lang,
          };
        })
        .filter((item) => item.text.length > 0);
    }

    return nodes
      .map((node) => ({
        id: node.dataset.sentenceId || '',
        text: node.textContent?.trim() || '',
        lang,
      }))
      .filter((item) => item.text.length > 0);
  }, []);

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

  // Background prefetch for next page audio
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
        const text = nodes
          .map((n) => n.textContent?.trim() || '')
          .filter((t) => t.length > 0)
          .join(' ');
        if (!text) return;

        const provider = serverSecrets?.audioProvider || 'device';
        if (provider === 'device') return;
        const isVi = nextMode === 'vi';
        const langTag = isVi ? 'vi-VN' : 'en-US';
        const voice = isVi
          ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : ''))
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
      highlightSentence(null);

      setMode(newMode);
      currentSentenceIndexRef.current = 0;
      setCurrentSentenceIndex(0);
      setError(null);

      const list = extractSentencesForMode(newMode);
      setSentences(list);
      updateSentenceOffsets(list);
      if (list[0]) {
        highlightSentence(list[0].id, list[0].lang);
      }
    },
    [extractSentencesForMode, highlightSentence, updateSentenceOffsets],
  );

  // Play full page audio
  const startFullPagePlayback = useCallback(
    async (startIndex: number, currentList: SentenceItem[]) => {
      if (currentList.length === 0) {
        setError('Không tìm thấy nội dung văn bản trên trang này.');
        setIsPlaying(false);
        playingRef.current = false;
        return;
      }

      setIsPlaying(true);
      playingRef.current = true;
      setError(null);

      const pageText = currentList.map((s) => s.text).join(' ');
      const provider = serverSecrets?.audioProvider || 'device';
      const isVi = mode === 'vi';
      const langTag = isVi ? 'vi-VN' : 'en-US';
      const voice = isVi
        ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : ''))
        : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));

      // Prefetch NEXT page audio in the background while this page is starting
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
              }
            }
          },
        );

        if (!playingRef.current) return;

        // Page audio completed
        if (autoPageTurn && currentPage < totalPage) {
          shouldAutoPlayNextPageRef.current = true;
          onNextPage();
        } else {
          setIsPlaying(false);
          playingRef.current = false;
          highlightSentence(null);
        }
      } catch (err: any) {
        if (!playingRef.current) return;
        console.error('[Audiobook] Playback error:', err);
        setError(err.message || 'Lỗi phát âm thanh');
        setIsPlaying(false);
        playingRef.current = false;
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
    ],
  );

  // Play / Resume
  const play = useCallback(() => {
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
      resumeCurrentAudio().catch((err) => {
        console.warn('[Audiobook] Resume failed, restarting:', err);
        startFullPagePlayback(currentSentenceIndexRef.current, list);
      });
      return;
    }

    startFullPagePlayback(currentSentenceIndexRef.current, list);
  }, [sentences, extractSentencesForMode, mode, updateSentenceOffsets, startFullPagePlayback]);

  // Pause
  const pause = useCallback(() => {
    shouldAutoPlayNextPageRef.current = false;
    setIsPlaying(false);
    playingRef.current = false;
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
    [sentences, highlightSentence, isPlaying, startFullPagePlayback],
  );

  const nextSentence = useCallback(() => {
    seekToSentence(currentSentenceIndexRef.current + 1);
  }, [seekToSentence]);

  const prevSentence = useCallback(() => {
    seekToSentence(currentSentenceIndexRef.current - 1);
  }, [seekToSentence]);

  // Re-extract sentences when page or viewMode changes, and auto-continue playback on page change
  useEffect(() => {
    const timer = setTimeout(() => {
      const extracted = extractSentencesForMode(mode);
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
    }, 250);

    return () => clearTimeout(timer);
  }, [currentPage, viewMode, mode, extractSentencesForMode, updateSentenceOffsets, startFullPagePlayback]);

  // Clean up on unmount
  useEffect(() => {
    return () => {
      playingRef.current = false;
      stopCurrentAudio();
      highlightSentence(null);
    };
  }, [highlightSentence]);

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
