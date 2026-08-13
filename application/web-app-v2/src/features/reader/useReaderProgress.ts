import { useCallback, useRef } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiFetch, apiJson } from '@/lib/api-client';
import type { ReadingProgress, ViewMode } from '@/types/api';
import { saveLocalProgress } from './localProgress';

/**
 * Server reading progress for a book, keyed by slug so switching books can never
 * apply the previous book's response (v1's cross-book race, review #4). Returns
 * undefined while loading / on error; callers fall back to local progress.
 */
export function useServerProgress(slug: string | undefined) {
  return useQuery({
    queryKey: ['progress', slug],
    enabled: !!slug,
    queryFn: () => apiJson<ReadingProgress>(`/api/books/${encodeURIComponent(slug!)}/progress`),
    staleTime: Infinity,
  });
}

/**
 * Write-through progress saver: updates localStorage immediately and POSTs to the
 * server debounced, so rapid page turns don't spam the API. Fire-and-forget; a
 * failed POST keeps the local copy (offline-friendly).
 */
export function useSaveProgress(slug: string | undefined) {
  const timer = useRef<number | undefined>(undefined);

  return useCallback(
    (page: number, viewMode: ViewMode) => {
      if (!slug) return;
      saveLocalProgress(slug, { page, viewMode });

      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        void apiFetch(`/api/books/${encodeURIComponent(slug)}/progress`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ page, viewMode }),
        }).catch(() => {
          /* offline / transient — local copy is the source of truth */
        });
      }, 400);
    },
    [slug],
  );
}
