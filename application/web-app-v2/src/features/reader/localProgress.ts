import { readJSON, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { ViewMode } from '@/types/api';

export interface LocalProgress {
  page: number;
  viewMode: ViewMode;
  /** Epoch MILLISECONDS of the last local save — the client-side half of the
   * shelf order's effectiveLastRead (features/library/bookOrder.ts). Absent on
   * entries written by v1 and by builds before the shelf order landed; that
   * means "unknown", never "now". */
  lastRead?: number;
}

/** Read the last-known local reading position for a book (for the card progress
 * bar, instant resume, and the shelf order), independent of the server copy. */
export function getLocalProgress(slug: string): LocalProgress | null {
  const value = readJSON<LocalProgress | null>(STORAGE_KEYS.progress(slug), null);
  if (!value || typeof value.page !== 'number') return null;
  // Drop a non-numeric lastRead so callers can trust the type on legacy entries.
  if (typeof value.lastRead !== 'number' || !Number.isFinite(value.lastRead)) {
    const { page, viewMode } = value;
    return { page, viewMode };
  }
  return value;
}

/** Write local progress, stamping the save time unless the caller supplied one.
 * Stamped here so every writer feeds the shelf order without remembering to. */
export function saveLocalProgress(slug: string, progress: LocalProgress): void {
  writeJSON(STORAGE_KEYS.progress(slug), {
    ...progress,
    lastRead: progress.lastRead ?? Date.now(),
  });
}
