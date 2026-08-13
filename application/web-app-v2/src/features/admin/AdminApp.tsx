import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from '@/app/queryClient';

/**
 * Admin entry (separate Vite bundle from the reader SPA). Tabs — books/upload,
 * users/permissions, API keys, change password — are ported in Phase 9 with
 * escaped JSX rendering (replacing v1's innerHTML template strings) and
 * JSON-body API calls.
 */
export function AdminApp() {
  return (
    <QueryClientProvider client={queryClient}>
      <div style={{ display: 'grid', placeItems: 'center', height: '100%', gap: 8 }}>
        <h1 style={{ font: '600 20px var(--font-sans)' }}>Admin</h1>
        <p style={{ color: 'var(--text-muted)' }}>Bilingual Reader v2 — scaffold</p>
      </div>
    </QueryClientProvider>
  );
}
