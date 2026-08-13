/**
 * Admin data layer: server shapes + React Query hooks.
 *
 * Reads go through `apiJson` (in-memory bearer token, 401→refresh→retry, and
 * FastAPI `detail` flattening). Mutations live in the tab components with their
 * own in-flight guards; on success they invalidate the `['admin']` key prefix so
 * every table refetches — the React-Query equivalent of v1's `loadDashboardData`.
 */
import { useQuery } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import type { Book } from '@/types/api';

/** GET /api/admin/users item (has the numeric id permissions are keyed by). */
export interface AdminUser {
  id: number;
  username: string;
  is_admin: boolean;
}

/** GET /api/admin/permissions item. */
export interface Permission {
  id: number;
  user_id: number;
  book_slug: string;
}

/** GET /api/admin/apikeys item. `key_value` is the full secret; only shown in
 * the table as a truncated prefix. */
export interface ApiKey {
  id: number;
  name: string;
  key_value: string;
  is_active: boolean;
  created_at?: string;
}

/** POST /api/admin/apikeys response — the one and only time the full key is shown. */
export interface CreateApiKeyResponse {
  ok: boolean;
  name: string;
  key_value: string;
}

/** Prefix used by every admin query key, so one invalidate refetches them all. */
export const ADMIN_QUERY_KEY = ['admin'] as const;

export function useAdminBooks() {
  return useQuery({
    queryKey: [...ADMIN_QUERY_KEY, 'books'],
    queryFn: () => apiJson<Book[]>('/api/books'),
  });
}

export function useAdminUsers() {
  return useQuery({
    queryKey: [...ADMIN_QUERY_KEY, 'users'],
    queryFn: () => apiJson<AdminUser[]>('/api/admin/users'),
  });
}

export function usePermissions() {
  return useQuery({
    queryKey: [...ADMIN_QUERY_KEY, 'permissions'],
    queryFn: () => apiJson<Permission[]>('/api/admin/permissions'),
  });
}

export function useApiKeys() {
  return useQuery({
    queryKey: [...ADMIN_QUERY_KEY, 'apikeys'],
    queryFn: () => apiJson<ApiKey[]>('/api/admin/apikeys'),
  });
}
