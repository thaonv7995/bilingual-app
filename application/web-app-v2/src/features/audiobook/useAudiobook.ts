import { useCallback, useEffect, useRef, useState } from 'react';
import { playSentenceAudio, stopCurrentAudio } from './audiobookService';
import { useServerSecrets } from '@/features/settings/serverSecrets';

export type AudiobookLanguageMode = 'en' | 'vi' | 'bilingual';

export interface SentenceItem {
  id: string;
  text: string;
  lang: 'en' | 'vi';
}

interface UseAudiobookOptions {
  bookSlug: string;
  currentPage: number;
  totalPage: number;
  viewMode: 'en' | 'vi' | 'split';
  enIframeRef: React.RefObject<HTMLIFrameElement | null>;
  viIframeRef: React.RefObject<HTMLIFrameElement | null>;
  onNextPage: () => void;
  onPrevPage: () => void;
}

export function useAudiobook({
  currentPage,
  totalPage,
  viewMode,
  enIframeRef,
  viIframeRef,
  onNextPage,
}: Omit<UseAudiobookOptions, 'bookSlug' | 'onPrevPage'>) {
  const { data: serverSecrets } = useServerSecrets();
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentSentenceIndex, setCurrentSentenceIndex] = useState(0);
  const [sentences, setSentences] = useState<SentenceItem[]>([]);
  const [mode, setMode] = useState<AudiobookLanguageMode>('en');
  const [speed, setSpeed] = useState<string>(() => serverSecrets?.speechSpeed || '1.0');
  const [autoPageTurn, setAutoPageTurn] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const playingRef = useRef(false);
  const abortControllerRef = useRef<boolean>(false);

  // Sync speed with server settings when loaded
  useEffect(() => {
    if (serverSecrets?.speechSpeed) {
      setSpeed(serverSecrets.speechSpeed);
    }
  }, [serverSecrets?.speechSpeed]);

  // Extract sentences from iframe DOM
  const extractSentences = useCallback(() => {
    const getDocSentences = (iframe: HTMLIFrameElement | null, lang: 'en' | 'vi'): SentenceItem[] => {
      if (!iframe || !iframe.contentDocument) return [];
      const doc = iframe.contentDocument;
      const nodes = Array.from(doc.querySelectorAll<HTMLElement>('.sentence-node'));
      return nodes
        .map((node) => ({
          id: node.dataset.sentenceId || '',
          text: node.textContent?.trim() || '',
          lang,
        }))
        .filter((item) => item.text.length > 0);
    };

    const enList = getDocSentences(enIframeRef.current, 'en');
    const viList = getDocSentences(viIframeRef.current, 'vi');

    if (mode === 'en' || (mode === 'bilingual' && viewMode === 'en')) {
      return enList.length > 0 ? enList : viList;
    }
    if (mode === 'vi' || (mode === 'bilingual' && viewMode === 'vi')) {
      return viList.length > 0 ? viList : enList;
    }

    if (mode === 'bilingual' && viewMode === 'split') {
      // Interleave EN sentence then VI sentence
      const maxLen = Math.max(enList.length, viList.length);
      const interleaved: SentenceItem[] = [];
      for (let i = 0; i < maxLen; i++) {
        if (enList[i]) interleaved.push(enList[i]!);
        if (viList[i]) interleaved.push(viList[i]!);
      }
      return interleaved;
    }

    return enList.length > 0 ? enList : viList;
  }, [mode, viewMode, enIframeRef, viIframeRef]);

  // Highlight and scroll sentence in iframes
  const highlightSentence = useCallback(
    (sentenceId: string | null) => {
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
      applyToDoc(enIframeRef.current);
      applyToDoc(viIframeRef.current);
    },
    [enIframeRef, viIframeRef],
  );

  // Re-extract sentences when page or mode changes
  useEffect(() => {
    // Wait for iframe content to be ready
    const timer = setTimeout(() => {
      const extracted = extractSentences();
      setSentences(extracted);
      if (currentSentenceIndex >= extracted.length) {
        setCurrentSentenceIndex(0);
      }
    }, 300);

    return () => clearTimeout(timer);
  }, [currentPage, mode, viewMode, extractSentences]);

  // Main playback loop
  const playLoop = useCallback(
    async (startIndex: number, currentList: SentenceItem[]) => {
      if (startIndex >= currentList.length) {
        // Reached end of page
        if (autoPageTurn && currentPage < totalPage) {
          onNextPage();
          setCurrentSentenceIndex(0);
          // Playback will continue after page load via next effect
        } else {
          setIsPlaying(false);
          playingRef.current = false;
          highlightSentence(null);
        }
        return;
      }

      const item = currentList[startIndex];
      if (!item) return;

      setCurrentSentenceIndex(startIndex);
      highlightSentence(item.id);
      setError(null);

      try {
        const provider = serverSecrets?.audioProvider || 'device';
        const voice = serverSecrets?.audioVoice || '';
        const langTag = item.lang === 'vi' ? 'vi-VN' : 'en-US';

        await playSentenceAudio({
          text: item.text,
          provider,
          voice,
          speed,
          lang: langTag,
        });

        if (abortControllerRef.current || !playingRef.current) {
          return;
        }

        // Brief natural pause between sentences (250ms)
        await new Promise((resolve) => setTimeout(resolve, 250));

        if (abortControllerRef.current || !playingRef.current) {
          return;
        }

        // Proceed to next sentence
        playLoop(startIndex + 1, currentList);
      } catch (err: any) {
        if (abortControllerRef.current || !playingRef.current) return;
        console.error('[Audiobook] Playback error:', err);
        setError(err.message || 'Lỗi phát âm thanh');
        setIsPlaying(false);
        playingRef.current = false;
      }
    },
    [autoPageTurn, currentPage, totalPage, onNextPage, highlightSentence, serverSecrets, speed],
  );

  const play = useCallback(() => {
    let list = sentences;
    if (list.length === 0) {
      list = extractSentences();
      setSentences(list);
    }
    if (list.length === 0) {
      setError('Không tìm thấy nội dung văn bản trên trang này.');
      return;
    }
    setIsPlaying(true);
    playingRef.current = true;
    abortControllerRef.current = false;
    playLoop(currentSentenceIndex, list);
  }, [sentences, extractSentences, currentSentenceIndex, playLoop]);

  const pause = useCallback(() => {
    setIsPlaying(false);
    playingRef.current = false;
    abortControllerRef.current = true;
    stopCurrentAudio();
  }, []);

  const nextSentence = useCallback(() => {
    stopCurrentAudio();
    const nextIdx = Math.min(sentences.length - 1, currentSentenceIndex + 1);
    setCurrentSentenceIndex(nextIdx);
    if (isPlaying) {
      abortControllerRef.current = false;
      playLoop(nextIdx, sentences);
    } else {
      highlightSentence(sentences[nextIdx]?.id || null);
    }
  }, [sentences, currentSentenceIndex, isPlaying, playLoop, highlightSentence]);

  const prevSentence = useCallback(() => {
    stopCurrentAudio();
    const prevIdx = Math.max(0, currentSentenceIndex - 1);
    setCurrentSentenceIndex(prevIdx);
    if (isPlaying) {
      abortControllerRef.current = false;
      playLoop(prevIdx, sentences);
    } else {
      highlightSentence(sentences[prevIdx]?.id || null);
    }
  }, [sentences, currentSentenceIndex, isPlaying, playLoop, highlightSentence]);

  // Clean up on unmount or page change
  useEffect(() => {
    return () => {
      abortControllerRef.current = true;
      playingRef.current = false;
      stopCurrentAudio();
      highlightSentence(null);
    };
  }, [currentPage, highlightSentence]);

  return {
    isPlaying,
    currentSentenceIndex,
    totalSentences: sentences.length,
    currentSentence: sentences[currentSentenceIndex] || null,
    mode,
    setMode,
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
