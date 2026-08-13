import { useQuery } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import type { Book } from '@/types/api';

/** GET /api/books — the permission-filtered library for the current user. */
export function useBooks() {
  return useQuery({
    queryKey: ['books'],
    queryFn: () => apiJson<Book[]>('/api/books'),
  });
}
