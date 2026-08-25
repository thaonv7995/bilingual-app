import { useCallback, useRef } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { apiFetch, apiJson } from '@/lib/api-client';
import { invalidateBooks } from '@/features/library/useBooks';
import type { ReadingProgress, ViewMode } from '@/types/api';
import { saveLocalProgress } from './localProgress';

/**
 * Server reading progress for a book, keyed by slug so switching books can never
 * apply the previous book's response (v1's cross-book race, review #4). Returns
 * undefined while loading / on error; callers fall back to local progress.
 *
 * The backend is the source of trust when opening a book, so every reader mount
 * refetches instead of trusting a session-old cache — otherwise progress made
 * on another device mid-session would never be seen. Callers must wait for
 * `isFetching` to clear before reconciling, or they'd reconcile against the
 * stale cached copy the refetch is about to replace.
 */
export function useServerProgress(slug: string | undefined) {
  return useQuery({
    queryKey: ['progress', slug],
    enabled: !!slug,
    queryFn: () => apiJson<ReadingProgress>(`/api/books/${encodeURIComponent(slug!)}/progress`),
    staleTime: 0,
    refetchOnMount: 'always',
  });
}

/**
 * Write-through progress saver: updates localStorage immediately and POSTs to the
 * server debounced, so rapid page turns don't spam the API. Fire-and-forget; a
 * failed POST keeps the local copy (offline-friendly).
 *
 * The POST carries `lastRead` (unix seconds — the moment `at` the save was
 * requested, NOT when the debounce fires) and the server keeps whichever copy
 * is newest, so a delayed write from this device can no longer clobber newer
 * progress saved from another. Pass `at` (epoch ms) only to re-send an existing
 * record with its original timestamp (see ReaderView's open-time reconcile);
 * real reading actions omit it and get stamped "now".
 *
 * A successful POST also moves the book to the top of the server's shelf order
 * (it sets last_read), so the cached book list is now out of date — invalidate
 * it. Failure needs no invalidation: nothing changed server-side, and the local
 * timestamp already reorders the shelf on its own.
 */
export function useSaveProgress(slug: string | undefined) {
  const timer = useRef<number | undefined>(undefined);
  const queryClient = useQueryClient();

  return useCallback(
    (page: number, viewMode: ViewMode, at?: number) => {
      if (!slug) return;
      const lastReadMs = at ?? Date.now();
      saveLocalProgress(slug, { page, viewMode, lastRead: lastReadMs });

      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        void apiFetch(`/api/books/${encodeURIComponent(slug)}/progress`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ page, viewMode, lastRead: Math.floor(lastReadMs / 1000) }),
        })
          .then(() => invalidateBooks(queryClient))
          .catch(() => {
            /* offline / transient — local copy is the source of truth */
          });
      }, 400);
    },
    [slug, queryClient],
  );
}
