import { readJSON, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { Highlight } from '@/types/api';

/** Per-book highlights in localStorage, shape { highlights: [] } (matches v1 so
 * a user's existing highlights load unchanged). The imperative DOM layer reads
 * these directly, so localStorage is the source of truth for what's painted. */
export function loadHighlights(slug: string): Highlight[] {
  const parsed = readJSON<{ highlights?: Highlight[] } | null>(STORAGE_KEYS.highlights(slug), null);
  return parsed?.highlights ?? [];
}

export function saveHighlights(slug: string, highlights: Highlight[]): void {
  writeJSON(STORAGE_KEYS.highlights(slug), { highlights });
}
