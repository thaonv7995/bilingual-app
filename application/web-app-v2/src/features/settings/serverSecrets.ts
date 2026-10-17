import { useQuery } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import { consumeLegacySecrets } from './settingsStore';
import type { AudioSource, Settings } from './settingsStore';
import type { LayoutMode } from '@/features/reader/readerConstants';

/**
 * Canonical settings response shared by web and mobile.
 *
 * Public preferences are returned in full. Secret values are never returned;
 * clients only receive availability flags and may replace or clear a secret
 * explicitly through PUT.
 */
export interface ServerSettings extends Settings {
  hasLlmKey: boolean;
  hasRealtimeKey: boolean;
  audioProvider: string;
  audioVoice: string;
  audioVoiceEn: string;
  audioVoiceVi: string;
  speechSpeed: string;
  hasAzureKey: boolean;
  hasElevenLabsKey: boolean;
  vocaOrigin: string;
  hasVocaToken: boolean;
}

export const USER_SETTINGS_KEY = ['user-settings'] as const;

export type ServerSettingsPatch = Partial<{
  provider: string;
  baseURL: string;
  model: string;
  realtimeModel: string;
  realtimeVoice: string;
  ttsModel: string;
  audioSource: AudioSource;
  layoutMode: LayoutMode;
  hideFinishedBooks: boolean;
  llmApiKey: string;
  realtimeApiKey: string;
  audioProvider: string;
  audioVoice: string;
  audioVoiceEn: string;
  audioVoiceVi: string;
  speechSpeed: string;
  azureApiKey: string;
  elevenLabsApiKey: string;
  vocaOrigin: string;
  vocaToken: string;
}>;

export function getServerSettings(): Promise<ServerSettings> {
  return apiJson<ServerSettings>('/api/user/settings');
}

export function useServerSettings() {
  return useQuery({
    queryKey: USER_SETTINGS_KEY,
    queryFn: getServerSettings,
    staleTime: 60_000,
  });
}

/**
 * Persist a partial settings update.
 *
 * Omit a field to keep its current value. For secret fields, send an empty
 * string only when the user explicitly wants to clear the server-side value.
 */
export async function saveServerSettings(
  patch: ServerSettingsPatch,
): Promise<ServerSettings> {
  return apiJson<ServerSettings>('/api/user/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  });
}

// Compatibility aliases while callers are migrated to the unified naming.
export type ServerSecrets = ServerSettings;
export const useServerSecrets = useServerSettings;
export const saveServerSecrets = saveServerSettings;

/**
 * v1 shipped this Voca key hardcoded in the bundle, so it is public and burnt —
 * migrating it would only push a dead credential to the server.
 */
const LEAKED_V1_VOCA_TOKEN = 'voca_55c2ac41266be58e43d0ef2b5817b4c9053a2ed7410fcefd';

/**
 * One-shot: push any legacy localStorage secrets to the server so users keep
 * working without re-entering. Only fills fields the server doesn't already have
 * (never clobbers a value set in v2). Returns true if it migrated anything.
 * Consumes the legacy secrets, so it's a no-op on subsequent calls.
 *
 * The legacy Voca ORIGIN is deliberately not migrated: it points at the retired
 * voca-bridge host, so carrying it over would break every call under Voca 2.0.
 */
export async function migrateLegacySecrets(): Promise<boolean> {
  const legacy = consumeLegacySecrets();
  if (!legacy.apiKey && !legacy.realtimeApiKey && !legacy.vocaBridgeToken) {
    return false;
  }
  let current: ServerSettings | null = null;
  try {
    current = await getServerSettings();
  } catch {
    /* offline / not ready — fall through and attempt the migration anyway */
  }
  const patch: ServerSettingsPatch = {};
  if (legacy.apiKey && !current?.hasLlmKey) patch.llmApiKey = legacy.apiKey;
  if (legacy.realtimeApiKey && !current?.hasRealtimeKey) patch.realtimeApiKey = legacy.realtimeApiKey;
  if (legacy.vocaBridgeToken && legacy.vocaBridgeToken !== LEAKED_V1_VOCA_TOKEN && !current?.hasVocaToken) {
    patch.vocaToken = legacy.vocaBridgeToken;
  }
  if (!Object.keys(patch).length) return false;
  try {
    await saveServerSettings(patch);
    return true;
  } catch {
    return false;
  }
}
