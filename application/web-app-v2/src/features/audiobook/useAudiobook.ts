import { useCallback, useEffect, useRef, useState } from 'react';
import { playSentenceAudio, stopCurrentAudio } from './audiobookService';
import { useServerSecrets } from '@/features/settings/serverSecrets';
import { segmentDocSentences } from '../reader/iframe/segmentation';

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

  // Extract sentences for a given mode
  const extractSentencesForMode = useCallback(
    (targetMode: AudiobookLanguageMode): SentenceItem[] => {
      const enList = getDocSentences(enIframeRef.current, 'en');
      const viList = getDocSentences(viIframeRef.current, 'vi');

      if (targetMode === 'en') {
        return enList.length > 0 ? enList : viList;
      }
      if (targetMode === 'vi') {
        return viList.length > 0 ? viList : enList;
      }
      if (targetMode === 'bilingual') {
        if (enList.length > 0 && viList.length > 0) {
          const maxLen = Math.max(enList.length, viList.length);
          const interleaved: SentenceItem[] = [];
          for (let i = 0; i < maxLen; i++) {
            if (enList[i]) interleaved.push(enList[i]!);
            if (viList[i]) interleaved.push(viList[i]!);
          }
          return interleaved;
        }
        return enList.length > 0 ? enList : viList;
      }
      return enList.length > 0 ? enList : viList;
    },
    [getDocSentences, enIframeRef, viIframeRef],
  );

  // Highlight and scroll sentence in iframes (targeted by lang to avoid scroll conflict)
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

  // Atomic mode change: cleanly stop audio, switch mode, re-extract, and reset index
  const changeMode = useCallback(
    (newMode: AudiobookLanguageMode) => {
      // 1. Immediately abort active playback
      abortControllerRef.current = true;
      playingRef.current = false;
      setIsPlaying(false);
      stopCurrentAudio();
      highlightSentence(null);

      // 2. Set new mode & reset index
      setMode(newMode);
      setCurrentSentenceIndex(0);
      setError(null);

      // 3. Extract sentences synchronously with the new mode
      const list = extractSentencesForMode(newMode);
      setSentences(list);
      if (list[0]) {
        highlightSentence(list[0].id, list[0].lang);
      }
    },
    [extractSentencesForMode, highlightSentence],
  );

  // Re-extract sentences when page or viewMode changes
  useEffect(() => {
    const timer = setTimeout(() => {
      const extracted = extractSentencesForMode(mode);
      setSentences(extracted);
      if (currentSentenceIndex >= extracted.length) {
        setCurrentSentenceIndex(0);
      }
    }, 200);

    return () => clearTimeout(timer);
  }, [currentPage, viewMode, mode, extractSentencesForMode, currentSentenceIndex]);

  // Main playback loop
  const playLoop = useCallback(
    async (startIndex: number, currentList: SentenceItem[]) => {
      if (startIndex >= currentList.length) {
        // Reached end of page
        if (autoPageTurn && currentPage < totalPage) {
          onNextPage();
          setCurrentSentenceIndex(0);
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
      highlightSentence(item.id, item.lang);
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

        // Natural pause between sentences (250ms)
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
      list = extractSentencesForMode(mode);
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
  }, [sentences, extractSentencesForMode, mode, currentSentenceIndex, playLoop]);

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
    const item = sentences[nextIdx];
    if (item) {
      highlightSentence(item.id, item.lang);
    }
    if (isPlaying) {
      abortControllerRef.current = false;
      playLoop(nextIdx, sentences);
    }
  }, [sentences, currentSentenceIndex, isPlaying, playLoop, highlightSentence]);

  const prevSentence = useCallback(() => {
    stopCurrentAudio();
    const prevIdx = Math.max(0, currentSentenceIndex - 1);
    setCurrentSentenceIndex(prevIdx);
    const item = sentences[prevIdx];
    if (item) {
      highlightSentence(item.id, item.lang);
    }
    if (isPlaying) {
      abortControllerRef.current = false;
      playLoop(prevIdx, sentences);
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
