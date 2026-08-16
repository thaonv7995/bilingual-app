import { useQuery } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import { consumeLegacySecrets } from './settingsStore';

/**
 * Server-held secret status. The backend never returns raw secrets — only whether
 * each one is configured — so the browser learns "is a key set?" without holding it.
 */
export interface ServerSecrets {
  hasLlmKey: boolean;
  hasRealtimeKey: boolean;
  vocaOrigin: string;
  hasVocaToken: boolean;
}

export const USER_SETTINGS_KEY = ['user-settings'] as const;

export function useServerSecrets() {
  return useQuery({
    queryKey: USER_SETTINGS_KEY,
    queryFn: () => apiJson<ServerSecrets>('/api/user/settings'),
    staleTime: 60_000,
  });
}

/** PUT partial secrets/config; omit a field to keep it, send "" to clear it. */
export async function saveServerSecrets(patch: {
  llmApiKey?: string;
  realtimeApiKey?: string;
  vocaOrigin?: string;
  vocaToken?: string;
}): Promise<ServerSecrets> {
  return apiJson<ServerSecrets>('/api/user/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  });
}

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
  let current: ServerSecrets | null = null;
  try {
    current = await apiJson<ServerSecrets>('/api/user/settings');
  } catch {
    /* offline / not ready — fall through and attempt the migration anyway */
  }
  const patch: Parameters<typeof saveServerSecrets>[0] = {};
  if (legacy.apiKey && !current?.hasLlmKey) patch.llmApiKey = legacy.apiKey;
  if (legacy.realtimeApiKey && !current?.hasRealtimeKey) patch.realtimeApiKey = legacy.realtimeApiKey;
  if (legacy.vocaBridgeToken && legacy.vocaBridgeToken !== LEAKED_V1_VOCA_TOKEN && !current?.hasVocaToken) {
    patch.vocaToken = legacy.vocaBridgeToken;
  }
  if (!Object.keys(patch).length) return false;
  try {
    await saveServerSecrets(patch);
    return true;
  } catch {
    return false;
  }
}
