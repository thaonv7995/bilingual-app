/**
 * Client-side feature-flag defaults and pure resolution helpers.
 * Kept React-free so Node tests can import and verify it directly.
 */

export interface AppFeatures {
  audiobookEnabled: boolean;
}

export interface AppConfigResponse {
  features?: Partial<AppFeatures>;
}

export function parseFeatureFlagEnv(raw: unknown, fallback = false): boolean {
  if (typeof raw === 'boolean') return raw;
  if (typeof raw !== 'string') return fallback;
  const normalized = raw.trim().toLowerCase();
  if (!normalized) return fallback;
  if (normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on') {
    return true;
  }
  if (normalized === '0' || normalized === 'false' || normalized === 'no' || normalized === 'off') {
    return false;
  }
  return fallback;
}

function readViteEnv(key: string): unknown {
  const meta = import.meta as { env?: Record<string, unknown> } | undefined;
  return meta?.env?.[key];
}

export const DEFAULT_APP_FEATURES: AppFeatures = {
  audiobookEnabled: parseFeatureFlagEnv(readViteEnv('VITE_ENABLE_AUDIOBOOK'), false),
};

export function resolveAppFeatures(
  config?: AppConfigResponse | null,
  fallback: AppFeatures = DEFAULT_APP_FEATURES,
): AppFeatures {
  return {
    audiobookEnabled:
      typeof config?.features?.audiobookEnabled === 'boolean'
        ? config.features.audiobookEnabled
        : fallback.audiobookEnabled,
  };
}

