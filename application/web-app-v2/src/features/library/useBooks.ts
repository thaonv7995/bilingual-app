import { useQuery, type QueryClient } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import type { Book } from '@/types/api';

/** Query key for the shelf. Exported so the reader can invalidate it without
 * re-typing the string (a typo there silently disables the refresh). */
export const BOOKS_QUERY_KEY = ['books'] as const;

/** GET /api/books — the permission-filtered library for the current user,
 * already in shelf order (the client re-applies the same order, see bookOrder.ts). */
export function useBooks() {
  return useQuery({
    queryKey: BOOKS_QUERY_KEY,
    queryFn: () => apiJson<Book[]>('/api/books'),
  });
}

/**
 * Mark the shelf stale after reading activity changed a book's `lastRead`, so
 * the library refetches — and re-sorts with server data — the next time it
 * mounts. `refetchType: 'none'` deliberately skips an immediate refetch: the
 * reader is also subscribed to this key, and page turns must not each pull the
 * whole book list down again. The library's mount refetch (queries that are
 * invalidated count as stale) picks it up on the way back to the shelf.
 */
export function invalidateBooks(queryClient: QueryClient): void {
  void queryClient.invalidateQueries({ queryKey: BOOKS_QUERY_KEY, refetchType: 'none' });
}
