import { useQuery } from '@tanstack/react-query';
import { apiJson } from './api-client';
import {
  DEFAULT_APP_FEATURES,
  resolveAppFeatures,
  type AppConfigResponse,
  type AppFeatures,
} from './featureConfig';

export * from './featureConfig';

export const APP_CONFIG_QUERY_KEY = ['app-config'] as const;

export function getAppConfig(): Promise<AppConfigResponse> {
  return apiJson<AppConfigResponse>('/api/config');
}

export function useFeatureFlags(): AppFeatures {
  const { data } = useQuery({
    queryKey: APP_CONFIG_QUERY_KEY,
    queryFn: getAppConfig,
    staleTime: 60_000,
    retry: 1,
  });
  return resolveAppFeatures(data, DEFAULT_APP_FEATURES);
}

