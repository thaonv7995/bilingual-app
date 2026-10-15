import { speakWithDevice } from '@/lib/speech';
import { apiFetch } from '@/lib/api-client';

export interface SynthesizeOptions {
  text: string;
  provider?: string;
  voice?: string;
  speed?: string;
  lang?: string;
}

// In-memory cache for synthesized audio Object URLs to prevent redundant network downloads
const audioBlobCache = new Map<string, string>();
const ongoingPrefetches = new Map<string, Promise<string>>();
let currentAudioElement: HTMLAudioElement | null = null;

export function getCurrentAudioElement(): HTMLAudioElement | null {
  return currentAudioElement;
}

export function getAudioDuration(): number {
  return currentAudioElement?.duration || 0;
}

export function seekAudio(timeSeconds: number): void {
  if (currentAudioElement) {
    currentAudioElement.currentTime = Math.max(0, timeSeconds);
  }
}

export function pauseCurrentAudio(): void {
  if (currentAudioElement) {
    currentAudioElement.pause();
  }
  if (typeof window !== 'undefined' && 'speechSynthesis' in window) {
    window.speechSynthesis.pause();
  }
}

export async function resumeCurrentAudio(): Promise<void> {
  if (currentAudioElement) {
    await currentAudioElement.play();
  } else if (typeof window !== 'undefined' && 'speechSynthesis' in window) {
    window.speechSynthesis.resume();
  }
}

export function stopCurrentAudio(): void {
  if (typeof window !== 'undefined' && 'speechSynthesis' in window) {
    window.speechSynthesis.cancel();
  }
  if (currentAudioElement) {
    currentAudioElement.pause();
    currentAudioElement.currentTime = 0;
    currentAudioElement = null;
  }
}

export function clearAudioCache(): void {
  for (const url of audioBlobCache.values()) {
    try {
      URL.revokeObjectURL(url);
    } catch {}
  }
  audioBlobCache.clear();
  ongoingPrefetches.clear();
}

/**
 * Prefetches synthesized audio in the background and caches the Object URL.
 */
export async function prefetchAudio(options: SynthesizeOptions): Promise<string> {
  const { text, provider = 'device', voice = '', speed = '1.0', lang = 'en-US' } = options;
  const trimmed = text.trim();
  if (!trimmed || provider === 'device') return '';

  const cacheKey = `${provider}:${voice}:${speed}:${lang}:${trimmed}`;
  if (audioBlobCache.has(cacheKey)) {
    return audioBlobCache.get(cacheKey)!;
  }
  if (ongoingPrefetches.has(cacheKey)) {
    return ongoingPrefetches.get(cacheKey)!;
  }

  const prefetchPromise = (async () => {
    try {
      const res = await apiFetch('/api/audio/synthesize', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          text: trimmed,
          provider,
          voice,
          speed,
          lang: lang.startsWith('vi') ? 'vi' : 'en',
        }),
      });
      if (!res.ok) return '';
      const blob = await res.blob();
      const audioUrl = URL.createObjectURL(blob);
      audioBlobCache.set(cacheKey, audioUrl);
      return audioUrl;
    } catch {
      return '';
    } finally {
      ongoingPrefetches.delete(cacheKey);
    }
  })();

  ongoingPrefetches.set(cacheKey, prefetchPromise);
  return prefetchPromise;
}

export const prefetchSentenceAudio = prefetchAudio;

/**
 * Synthesizes and plays audio for a piece of text (e.g. full page).
 * Emits time updates during playback for continuous highlight tracking.
 */
export async function playPageAudio(
  options: SynthesizeOptions,
  onTimeUpdate?: (currentTime: number, duration: number) => void,
): Promise<void> {
  const { text, provider = 'device', voice = '', speed = '1.0', lang = 'en-US' } = options;
  const trimmed = text.trim();
  if (!trimmed) return;

  stopCurrentAudio();

  // 1. Device Local Speech (Offline Web Speech API)
  if (provider === 'device') {
    return speakWithDevice(trimmed, lang);
  }

  // 2. Cloud Providers via Backend Proxy (/api/audio/synthesize)
  const cacheKey = `${provider}:${voice}:${speed}:${lang}:${trimmed}`;
  let audioUrl = audioBlobCache.get(cacheKey);

  if (!audioUrl && ongoingPrefetches.has(cacheKey)) {
    audioUrl = await ongoingPrefetches.get(cacheKey);
  }

  if (!audioUrl) {
    const res = await apiFetch('/api/audio/synthesize', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        text: trimmed,
        provider,
        voice,
        speed,
        lang: lang.startsWith('vi') ? 'vi' : 'en',
      }),
    });

    if (!res.ok) {
      const err = await res.text();
      throw new Error(`TTS synthesis error (${res.status}): ${err}`);
    }

    const blob = await res.blob();
    audioUrl = URL.createObjectURL(blob);
    audioBlobCache.set(cacheKey, audioUrl);
  }

  return new Promise<void>((resolve, reject) => {
    const audio = new Audio(audioUrl);
    currentAudioElement = audio;

    const cleanup = () => {
      audio.removeEventListener('timeupdate', handleTimeUpdate);
      audio.removeEventListener('ended', onEnded);
      audio.removeEventListener('error', onError);
      if (currentAudioElement === audio) {
        currentAudioElement = null;
      }
    };

    const handleTimeUpdate = () => {
      if (onTimeUpdate) {
        onTimeUpdate(audio.currentTime, audio.duration || 0);
      }
    };

    const onEnded = () => {
      cleanup();
      resolve();
    };

    const onError = () => {
      cleanup();
      reject(new Error('Audio playback error'));
    };

    audio.addEventListener('timeupdate', handleTimeUpdate);
    audio.addEventListener('ended', onEnded);
    audio.addEventListener('error', onError);

    try {
      audio.playbackRate = parseFloat(speed) || 1.0;
    } catch {
      audio.playbackRate = 1.0;
    }

    audio.play().catch((err) => {
      cleanup();
      reject(err);
    });
  });
}

export const playSentenceAudio = playPageAudio;
