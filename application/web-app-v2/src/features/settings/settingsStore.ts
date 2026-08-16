import { create } from 'zustand';
import { readJSON, readString, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { LayoutMode } from '@/features/reader/readerConstants';

/**
 * User AI/voca settings persisted in localStorage. NOTE: secrets do NOT live here
 * anymore — the LLM key, realtime key and Voca API key are stored server-side
 * (see `serverSecrets.ts` + `/api/user/settings`) so an XSS payload can't read them.
 * Only non-secret config (provider, base URL, model, layout, …) is kept locally.
 *
 * `ttsModel` is the only TTS knob left: Voca 2.0 synthesises audio itself, so the
 * client just names the voice (v1 also carried a TTS endpoint + an "use the API
 * for TTS" toggle, both dead once TTS moved server-side).
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
};

interface SettingsState {
  settings: Settings;
  setSettings: (patch: Partial<Settings>) => void;
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

// Migrate v1's standalone layoutMode key into settings if present.
const legacyLayout = readString(STORAGE_KEYS.layoutMode) as LayoutMode | null;

// Secret keys that older versions wrote into the localStorage settings blob. We
// capture them once (for server migration) and always strip them from storage.
const LEGACY_SECRET_KEYS: (keyof LegacySecrets)[] = ['apiKey', 'realtimeApiKey', 'vocaBridgeToken'];

// Config we only STRIP, never migrate: `vocaBridgeOrigin` pointed at the retired
// voca-bridge host, and the TTS endpoint/toggle died with client-side TTS.
const DEAD_SETTING_KEYS = ['vocaBridgeOrigin', 'ttsEndpoint', 'useApiTts'];

const persisted = readJSON<Record<string, unknown>>(STORAGE_KEYS.settings, {});
const captured: LegacySecrets = {};
let hadLegacySecret = false;
for (const k of LEGACY_SECRET_KEYS) {
  const v = persisted[k];
  if (typeof v === 'string' && v) {
    captured[k] = v;
    hadLegacySecret = true;
  }
  delete persisted[k];
}
if (hadLegacySecret) legacySecrets = captured;

let hadDeadKey = false;
for (const k of DEAD_SETTING_KEYS) {
  if (k in persisted) {
    delete persisted[k];
    hadDeadKey = true;
  }
}

const initialSettings: Settings = {
  ...DEFAULT_SETTINGS,
  ...(legacyLayout ? { layoutMode: legacyLayout } : {}),
  ...(persisted as Partial<Settings>),
};
// Rewrite storage without the stripped secrets/dead config so they don't linger.
if (hadLegacySecret || hadDeadKey) writeJSON(STORAGE_KEYS.settings, initialSettings);

export const useSettingsStore = create<SettingsState>((set) => ({
  settings: initialSettings,
  setSettings: (patch) =>
    set((s) => {
      const next = { ...s.settings, ...patch };
      writeJSON(STORAGE_KEYS.settings, next);
      return { settings: next };
    }),
}));
