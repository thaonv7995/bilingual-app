import { create } from 'zustand';
import { readJSON, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';

/**
 * User AI/voca settings. In v2 the voca-bridge origin/token are NOT here — they
 * live server-side (the proxy). Users still bring their own LLM key for chat and
 * card generation (hybrid model). The Settings modal UI lands in Phase 8.
 */
export interface Settings {
  provider: string;
  baseURL: string;
  apiKey: string;
  model: string;
  realtimeApiKey: string;
  realtimeModel: string;
  realtimeVoice: string;
  ttsEndpoint: string;
  ttsModel: string;
  useApiTts: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  provider: 'openai',
  baseURL: 'https://api.openai.com/v1',
  apiKey: '',
  model: 'gpt-4o-mini',
  realtimeApiKey: '',
  realtimeModel: 'gpt-realtime-mini',
  realtimeVoice: 'alloy',
  ttsEndpoint: '',
  ttsModel: 'edge-tts/en-US-SteffanNeural',
  useApiTts: true,
};

interface SettingsState {
  settings: Settings;
  setSettings: (patch: Partial<Settings>) => void;
}

export const useSettingsStore = create<SettingsState>((set) => ({
  settings: { ...DEFAULT_SETTINGS, ...readJSON<Partial<Settings>>(STORAGE_KEYS.settings, {}) },
  setSettings: (patch) =>
    set((s) => {
      const next = { ...s.settings, ...patch };
      writeJSON(STORAGE_KEYS.settings, next);
      return { settings: next };
    }),
}));
