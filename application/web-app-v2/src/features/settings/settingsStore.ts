import { create } from 'zustand';
import { readJSON, readString, remove } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { LayoutMode } from '@/features/reader/readerConstants';

/**
 * Runtime projection of the canonical settings stored on the server.
 *
 * This store exists so feature code can synchronously consume settings after the
 * authenticated bootstrap has completed. It is not a persistence layer:
 * - server data hydrates the store;
 * - successful server updates replace or patch the store;
 * - localStorage is read only once to migrate legacy data, then removed.
 */

/**
 * Where a word's pronunciation comes from. Voca 2.0 only produces audio when the
 * Voca SERVER has a TTS provider configured, so a Voca-only app is mute on that
 * server — hence the device's built-in speech synthesis as a fallback.
 *
 * This is NOT a revival of v1's `ttsEndpoint`/`useApiTts` (still purged below):
 * those named a client-side TTS credential that 2.0 refuses to accept. This one
 * picks between two audio *sources*, neither of which the client authenticates.
 */
export type AudioSource =
  /** Try Voca, fall back to the device voice when it can't deliver. */
  | 'auto'
  /** Voca only — surface the error instead of falling back. */
  | 'voca'
  /** Device only — never calls Voca audio at all (fastest, fully offline). */
  | 'device';

export interface Settings {
  provider: string;
  baseURL: string;
  model: string;
  realtimeModel: string;
  realtimeVoice: string;
  /** Voca-side voice id, sent as `voiceModel` on the audio POST. */
  ttsModel: string;
  audioSource: AudioSource;
  layoutMode: LayoutMode;
  hideFinishedBooks: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  provider: 'openai',
  baseURL: 'https://api.openai.com/v1',
  model: 'gpt-4o-mini',
  realtimeModel: 'gpt-realtime-mini',
  realtimeVoice: 'alloy',
  ttsModel: 'edge-tts/en-US-SteffanNeural',
  audioSource: 'auto',
  layoutMode: 'en-vi',
  hideFinishedBooks: true,
};

interface SettingsState {
  settings: Settings;
  hydrated: boolean;
  setSettings: (patch: Partial<Settings>) => void;
  replaceSettings: (settings: Settings) => void;
  resetSettings: () => void;
}

/**
 * Secrets that used to live in the localStorage settings blob (v1/early v2). We
 * capture them once at load, strip them from storage, and let App migrate them to
 * the server so users don't have to re-enter their key. Consumed exactly once.
 */
export interface LegacySecrets {
  apiKey?: string;
  realtimeApiKey?: string;
  vocaBridgeToken?: string;
}
let legacySecrets: LegacySecrets = {};
export function consumeLegacySecrets(): LegacySecrets {
  const out = legacySecrets;
  legacySecrets = {};
  return out;
}

// Legacy preferences are captured once so App can migrate them to the server.
const legacyLayout = readString(STORAGE_KEYS.layoutMode) as LayoutMode | null;

// Secret keys that older versions wrote into the localStorage settings blob. We
// capture them once (for server migration) and always strip them from storage.
const LEGACY_SECRET_KEYS: (keyof LegacySecrets)[] = ['apiKey', 'realtimeApiKey', 'vocaBridgeToken'];

// Config we only STRIP, never migrate: `vocaBridgeOrigin` pointed at the retired
// voca-bridge host, and the TTS endpoint/toggle died with client-side TTS.
const DEAD_SETTING_KEYS = ['vocaBridgeOrigin', 'ttsEndpoint', 'useApiTts'];

const persisted = readJSON<Record<string, unknown>>(STORAGE_KEYS.settings, {});
const captured: LegacySecrets = {};
for (const k of LEGACY_SECRET_KEYS) {
  const v = persisted[k];
  if (typeof v === 'string' && v) {
    captured[k] = v;
  }
}
legacySecrets = captured;

export const LEGACY_PUBLIC_SETTINGS: Partial<Settings> = {
  ...(legacyLayout ? { layoutMode: legacyLayout } : {}),
  ...(persisted as Partial<Settings>),
};
for (const key of [
  ...LEGACY_SECRET_KEYS,
  ...DEAD_SETTING_KEYS,
] as string[]) {
  delete (LEGACY_PUBLIC_SETTINGS as Record<string, unknown>)[key];
}

const initialSettings: Settings = {
  ...DEFAULT_SETTINGS,
  ...LEGACY_PUBLIC_SETTINGS,
};

// Settings must no longer survive locally. Remove all former persistence keys
// after capturing migration data.
remove(STORAGE_KEYS.settings);
remove(STORAGE_KEYS.layoutMode);

export const useSettingsStore = create<SettingsState>((set) => ({
  settings: initialSettings,
  hydrated: false,
  setSettings: (patch) =>
    set((s) => {
      const next = { ...s.settings, ...patch };
      return { settings: next };
    }),
  replaceSettings: (settings) =>
    set({
      settings: {
        ...DEFAULT_SETTINGS,
        ...settings,
      },
      hydrated: true,
    }),
  resetSettings: () =>
    set({
      settings: DEFAULT_SETTINGS,
      hydrated: false,
    }),
}));
