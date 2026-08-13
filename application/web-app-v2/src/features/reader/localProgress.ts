import { readJSON, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { ViewMode } from '@/types/api';

export interface LocalProgress {
  page: number;
  viewMode: ViewMode;
}

/** Read the last-known local reading position for a book (for the card progress
 * bar and instant resume), independent of the server copy. */
export function getLocalProgress(slug: string): LocalProgress | null {
  const value = readJSON<LocalProgress | null>(STORAGE_KEYS.progress(slug), null);
  if (value && typeof value.page === 'number') return value;
  return null;
}

export function saveLocalProgress(slug: string, progress: LocalProgress): void {
  writeJSON(STORAGE_KEYS.progress(slug), progress);
}
