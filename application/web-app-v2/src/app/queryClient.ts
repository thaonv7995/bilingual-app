import { QueryClient } from '@tanstack/react-query';

/**
 * Shared React Query client. Server state (books, highlights, progress) is keyed
 * by book slug so switching books cancels/ignores stale responses — the
 * structural fix for v1's cross-book fetch contamination (review #10/#11/#17).
 */
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});
