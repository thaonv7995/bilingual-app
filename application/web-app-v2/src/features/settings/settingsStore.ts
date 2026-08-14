import { create } from 'zustand';
import { readJSON, readString, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { LayoutMode } from '@/features/reader/readerConstants';

/**
 * User AI/voca settings persisted in localStorage. NOTE: secrets do NOT live here
 * anymore — the LLM key, realtime key and voca-bridge token are stored server-side
 * (see `serverSecrets.ts` + `/api/user/settings`) so an XSS payload can't read them.
 * Only non-secret config (provider, base URL, model, layout, …) is kept locally.
 */
export interface Settings {
  provider: string;
  baseURL: string;
  model: string;
  realtimeModel: string;
  realtimeVoice: string;
  ttsEndpoint: string;
  ttsModel: string;
  useApiTts: boolean;
  layoutMode: LayoutMode;
}

export const DEFAULT_SETTINGS: Settings = {
  provider: 'openai',
  baseURL: 'https://api.openai.com/v1',
  model: 'gpt-4o-mini',
  realtimeModel: 'gpt-realtime-mini',
  realtimeVoice: 'alloy',
  ttsEndpoint: '',
  ttsModel: 'edge-tts/en-US-SteffanNeural',
  useApiTts: true,
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
  vocaBridgeOrigin?: string;
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
const LEGACY_SECRET_KEYS: (keyof LegacySecrets)[] = [
  'apiKey',
  'realtimeApiKey',
  'vocaBridgeOrigin',
  'vocaBridgeToken',
];

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

const initialSettings: Settings = {
  ...DEFAULT_SETTINGS,
  ...(legacyLayout ? { layoutMode: legacyLayout } : {}),
  ...(persisted as Partial<Settings>),
};
// Rewrite storage without the stripped secrets so they don't linger on disk.
if (hadLegacySecret) writeJSON(STORAGE_KEYS.settings, initialSettings);

export const useSettingsStore = create<SettingsState>((set) => ({
  settings: initialSettings,
  setSettings: (patch) =>
    set((s) => {
      const next = { ...s.settings, ...patch };
      writeJSON(STORAGE_KEYS.settings, next);
      return { settings: next };
    }),
}));
