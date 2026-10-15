import { useCallback, useEffect, useRef, useState } from 'react';
import { playSentenceAudio, prefetchSentenceAudio, stopCurrentAudio } from './audiobookService';
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
  const shouldAutoPlayNextPageRef = useRef<boolean>(false);

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
        return enList.length > 0 ? enList : viList.map((item) => ({ ...item, lang: 'en' as const }));
      }
      if (targetMode === 'vi') {
        return viList.length > 0 ? viList : enList.map((item) => ({ ...item, lang: 'vi' as const }));
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
      shouldAutoPlayNextPageRef.current = false;
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

  // Main playback loop
  const playLoop = useCallback(
    async (startIndex: number, currentList: SentenceItem[]) => {
      if (startIndex >= currentList.length) {
        // Reached end of page
        if (autoPageTurn && currentPage < totalPage) {
          shouldAutoPlayNextPageRef.current = true;
          onNextPage();
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
        const isVi = (mode === 'vi') || (mode === 'bilingual' && item.lang === 'vi');
        const langTag = isVi ? 'vi-VN' : 'en-US';
        const voice = isVi
          ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : ''))
          : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));

        // Prefetch upcoming 1-2 sentences in the background for smooth zero-delay playback
        if (provider !== 'device') {
          for (let lookahead = 1; lookahead <= 2; lookahead++) {
            const nextIdx = startIndex + lookahead;
            const nextItem = currentList[nextIdx];
            if (!nextItem) continue;
            const nextIsVi = (mode === 'vi') || (mode === 'bilingual' && nextItem.lang === 'vi');
            const nextLangTag = nextIsVi ? 'vi-VN' : 'en-US';
            const nextVoice = nextIsVi
              ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : ''))
              : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));
            prefetchSentenceAudio({
              text: nextItem.text,
              provider,
              voice: nextVoice,
              speed,
              lang: nextLangTag,
            }).catch(() => {});
          }
        }

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

        // Natural pause between sentences (200ms)
        await new Promise((resolve) => setTimeout(resolve, 200));

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

  // Re-extract sentences when page or viewMode changes, and auto-continue playback on page change
  useEffect(() => {
    const timer = setTimeout(() => {
      const extracted = extractSentencesForMode(mode);
      setSentences(extracted);
      if (shouldAutoPlayNextPageRef.current) {
        shouldAutoPlayNextPageRef.current = false;
        if (extracted.length > 0) {
          setCurrentSentenceIndex(0);
          setIsPlaying(true);
          playingRef.current = true;
          abortControllerRef.current = false;
          playLoop(0, extracted);
        }
      } else if (currentSentenceIndex >= extracted.length) {
        setCurrentSentenceIndex(0);
      }
    }, 250);

    return () => clearTimeout(timer);
  }, [currentPage, viewMode, mode, extractSentencesForMode, currentSentenceIndex, playLoop]);

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
    shouldAutoPlayNextPageRef.current = false;

    // Prefetch immediately for the upcoming sentences
    const provider = serverSecrets?.audioProvider || 'device';
    if (provider !== 'device') {
      for (let lookahead = 0; lookahead <= 2; lookahead++) {
        const idx = currentSentenceIndex + lookahead;
        const nextItem = list[idx];
        if (!nextItem) continue;
        const nextIsVi = (mode === 'vi') || (mode === 'bilingual' && nextItem.lang === 'vi');
        const nextLangTag = nextIsVi ? 'vi-VN' : 'en-US';
        const nextVoice = nextIsVi
          ? (serverSecrets?.audioVoiceVi || (provider === 'azure' ? 'vi-VN-HoaiMyNeural' : provider === 'openai' ? 'alloy' : ''))
          : (serverSecrets?.audioVoiceEn || serverSecrets?.audioVoice || (provider === 'azure' ? 'en-US-JennyNeural' : provider === 'elevenlabs' ? '21m00Tcm4TlvDq8ikWAM' : 'alloy'));
        prefetchSentenceAudio({
          text: nextItem.text,
          provider,
          voice: nextVoice,
          speed,
          lang: nextLangTag,
        }).catch(() => {});
      }
    }

    playLoop(currentSentenceIndex, list);
  }, [sentences, extractSentencesForMode, mode, currentSentenceIndex, playLoop]);

  const pause = useCallback(() => {
    shouldAutoPlayNextPageRef.current = false;
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

  // Clean up on unmount
  useEffect(() => {
    return () => {
      abortControllerRef.current = true;
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
