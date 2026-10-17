/**
 * Media Session API integration for Lock Screen and Background playback controls.
 * Supported by modern mobile browsers (Safari on iOS, Chrome on Android, etc.) and desktop browsers.
 */

export interface MediaSessionMetadataOptions {
  title: string;
  artist?: string;
  album?: string;
  artwork?: Array<{ src: string; sizes?: string; type?: string }>;
}

export function updateMediaSessionMetadata(options: MediaSessionMetadataOptions): void {
  if (typeof window === 'undefined' || !('mediaSession' in navigator)) return;

  try {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: options.title,
      artist: options.artist || 'Bilingual Reader',
      album: options.album || 'Bilingual Reader',
      artwork: options.artwork || [
        { src: '/icon-192.png', sizes: '192x192', type: 'image/png' },
        { src: '/icon-512.png', sizes: '512x512', type: 'image/png' },
      ],
    });
  } catch (err) {
    console.warn('[MediaSession] Failed to update metadata:', err);
  }
}

export function updateMediaSessionPositionState(options: {
  duration: number;
  playbackRate?: number;
  position: number;
}): void {
  if (
    typeof window === 'undefined' ||
    !('mediaSession' in navigator) ||
    typeof navigator.mediaSession.setPositionState !== 'function'
  ) {
    return;
  }

  const { duration, playbackRate = 1.0, position } = options;
  if (!duration || isNaN(duration) || duration <= 0) return;

  try {
    const clampedPos = Math.min(Math.max(0, position), duration);
    navigator.mediaSession.setPositionState({
      duration: Math.max(0.1, duration),
      playbackRate: Math.max(0.25, playbackRate),
      position: clampedPos,
    });
  } catch {
    // Ignore harmless browser timing errors
  }
}

export function setMediaSessionPlaybackState(state: 'none' | 'paused' | 'playing'): void {
  if (typeof window === 'undefined' || !('mediaSession' in navigator)) return;
  try {
    navigator.mediaSession.playbackState = state;
  } catch {
    // Ignore unsupported browser states
  }
}

export interface MediaSessionActionHandlers {
  onPlay: () => void;
  onPause: () => void;
  onNextTrack?: () => void;
  onPreviousTrack?: () => void;
  onSeekTo?: (timeSeconds: number) => void;
  onSkipForward?: () => void;
  onSkipBackward?: () => void;
}

export function setupMediaSessionActionHandlers(handlers: MediaSessionActionHandlers): void {
  if (typeof window === 'undefined' || !('mediaSession' in navigator)) return;

  const actions: Array<[MediaSessionAction, ((details: MediaSessionActionDetails) => void) | null]> = [
    ['play', () => handlers.onPlay()],
    ['pause', () => handlers.onPause()],
    ['previoustrack', handlers.onPreviousTrack ? () => handlers.onPreviousTrack!() : null],
    ['nexttrack', handlers.onNextTrack ? () => handlers.onNextTrack!() : null],
    [
      'seekto',
      handlers.onSeekTo
        ? (details) => {
            if (typeof details.seekTime === 'number') {
              handlers.onSeekTo!(details.seekTime);
            }
          }
        : null,
    ],
    ['seekforward', handlers.onSkipForward ? () => handlers.onSkipForward!() : null],
    ['seekbackward', handlers.onSkipBackward ? () => handlers.onSkipBackward!() : null],
    ['stop', () => handlers.onPause()],
  ];

  for (const [action, handler] of actions) {
    try {
      if (handler) {
        navigator.mediaSession.setActionHandler(action, handler);
      } else {
        navigator.mediaSession.setActionHandler(action, null);
      }
    } catch {
      // Browser may not support specific actions (e.g. skipad)
    }
  }
}
