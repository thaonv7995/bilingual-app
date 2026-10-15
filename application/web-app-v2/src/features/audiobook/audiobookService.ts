import { speakWithDevice } from '@/lib/speech';

export interface SynthesizeOptions {
  text: string;
  provider?: string;
  voice?: string;
  speed?: string;
  lang?: string;
}

// In-memory cache for synthesized audio Object URLs to prevent redundant network downloads
const audioBlobCache = new Map<string, string>();
let currentAudioElement: HTMLAudioElement | null = null;

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

/**
 * Synthesizes or plays audio for a piece of text.
 * Returns a promise that resolves when playback has finished.
 */
export async function playSentenceAudio(options: SynthesizeOptions): Promise<void> {
  const { text, provider = 'device', voice = '', speed = '1.0', lang = 'en-US' } = options;
  const trimmed = text.trim();
  if (!trimmed) return;

  stopCurrentAudio();

  // 1. Device Local Speech (Offline Web Speech API)
  if (provider === 'device') {
    return speakWithDevice(trimmed, lang);
  }

  // 2. Cloud Providers via Backend Proxy (/api/audio/synthesize)
  const cacheKey = `${provider}:${voice}:${speed}:${trimmed}`;
  let audioUrl = audioBlobCache.get(cacheKey);

  if (!audioUrl) {
    const res = await fetch('/api/audio/synthesize', {
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
      audio.removeEventListener('ended', onEnded);
      audio.removeEventListener('error', onError);
      if (currentAudioElement === audio) {
        currentAudioElement = null;
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
